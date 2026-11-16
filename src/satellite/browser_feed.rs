//! Agent-browser feed on the node: ingest from the spawned `browser-mcp`
//! and a WebSocket the hub tunnels viewer connections onto.
//!
//! `POST /api/node/browser-feed` authenticates with the feed token the hub
//! minted for the thread and sent on the run request — not the node token —
//! so it lives outside the node-auth middleware. `GET
//! /api/node/browser-feed/ws` is node-authed like every other `/api/node/*`
//! route; the hub dials it with the thread's feed token in
//! [`crate::browser_feed::FEED_TOKEN_HEADER`].

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{State, WebSocketUpgrade};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::browser_feed::{idle_message, BrowserFeed, FeedPost};
use crate::satellite::SatelliteState;

/// Ingest route, mounted without the node-token middleware.
pub fn ingest_router() -> Router<Arc<SatelliteState>> {
    Router::new()
        .route("/api/node/browser-feed", post(ingest))
        .layer(axum::extract::DefaultBodyLimit::max(
            crate::browser_feed::MAX_POST_BODY_BYTES,
        ))
}

/// Viewer route, mounted inside the node-auth middleware.
pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new().route("/api/node/browser-feed/ws", get(ws))
}

/// How often the socket re-checks for a feed that has not registered yet:
/// a viewer can arrive before the agent launches its browser.
const FEED_POLL: Duration = Duration::from_millis(500);
const PING_INTERVAL: Duration = Duration::from_secs(30);

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.trim().strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

async fn ingest(
    State(state): State<Arc<SatelliteState>>,
    headers: HeaderMap,
    Json(post): Json<FeedPost>,
) -> Response {
    let token = bearer_token(&headers).unwrap_or("");
    match state.browser_feed(token).await {
        Some(feed) => {
            feed.publish(post);
            StatusCode::NO_CONTENT.into_response()
        }
        None => (
            StatusCode::UNAUTHORIZED,
            Json(crate::node::NodeError::new(
                "unauthorized",
                "invalid feed token",
            )),
        )
            .into_response(),
    }
}

async fn ws(
    ws: WebSocketUpgrade,
    State(state): State<Arc<SatelliteState>>,
    headers: HeaderMap,
) -> Response {
    // The token travels in a header rather than the query string so it
    // stays out of request logs.
    let Some(token) = headers
        .get(crate::browser_feed::FEED_TOKEN_HEADER)
        .and_then(|h| h.to_str().ok())
        .map(str::to_string)
    else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(crate::node::NodeError::new(
                "unauthorized",
                "missing feed token",
            )),
        )
            .into_response();
    };
    ws.on_upgrade(move |socket| serve(socket, state, token))
}

async fn serve(
    mut socket: axum::extract::ws::WebSocket,
    state: Arc<SatelliteState>,
    token: String,
) {
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;
    let mut sent_idle = false;

    let feed = loop {
        if let Some(feed) = state.browser_feed(&token).await {
            break feed;
        }
        if !sent_idle {
            sent_idle = true;
            if socket
                .send(axum::extract::ws::Message::Text(idle_message()))
                .await
                .is_err()
            {
                return;
            }
        }
        tokio::select! {
            msg = socket.recv() => {
                match msg {
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => return,
                    Some(Err(_)) => return,
                    _ => {}
                }
            }
            _ = ping.tick() => {
                if socket.send(axum::extract::ws::Message::Ping(vec![])).await.is_err() {
                    return;
                }
            }
            _ = tokio::time::sleep(FEED_POLL) => {}
        }
    };

    stream(socket, feed).await;
}

/// The latest frame first, then live posts until the socket closes.
async fn stream(mut socket: axum::extract::ws::WebSocket, feed: Arc<BrowserFeed>) {
    let mut rx = feed.subscribe();
    if let Some(latest) = feed.latest_message() {
        if socket
            .send(axum::extract::ws::Message::Text(latest))
            .await
            .is_err()
        {
            return;
        }
    }
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;
    loop {
        tokio::select! {
            msg = socket.recv() => {
                match msg {
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => return,
                    Some(Err(_)) => return,
                    _ => continue,
                }
            }
            frame = rx.recv() => {
                match frame {
                    Ok(text) => {
                        if socket
                            .send(axum::extract::ws::Message::Text(text))
                            .await
                            .is_err()
                        {
                            return;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                }
            }
            _ = ping.tick() => {
                if socket.send(axum::extract::ws::Message::Ping(vec![])).await.is_err() {
                    return;
                }
            }
        }
    }
}
