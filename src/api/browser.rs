//! Agent-browser feed endpoints.
//!
//! `POST /api/browser-feed` sits on the public router: the caller is a
//! `devinorium browser-mcp` subprocess authenticating with the per-thread
//! feed token minted at send time, not a session. Each POST carries the
//! newest viewport JPEG plus page metadata, which the thread's
//! [`crate::browser_feed::BrowserFeed`] stores and fans out.
//!
//! `GET /api/threads/:id/browser/ws` is the viewer side: authenticated
//! users on the thread's owner get the feed as JSON text messages —
//! `{"type":"frame",...}` carrying a base64 JPEG and `{"type":"status"}`
//! while no browser session is live. Threads bound to a satellite node
//! tunnel onto the node's own feed socket; the protocol is identical, so
//! frames pass through verbatim. The socket is strictly server-to-client:
//! the browser is view-only and no viewer input ever reaches it.

use std::time::Duration;

use axum::extract::{Extension, Path, State, WebSocketUpgrade};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};

use crate::auth::session::CurrentUser;
use crate::browser_feed::{idle_message, FeedPost};
use crate::security::ip::ClientIp;
use crate::security::rate_limit::charge_auth_failure;
use crate::AppState;

use super::{map_err_internal, ApiError};

/// Public ingest route (own auth inside the handler).
pub fn feed_router() -> Router<AppState> {
    Router::new()
        .route("/api/browser-feed", post(ingest))
        .layer(axum::extract::DefaultBodyLimit::max(
            crate::browser_feed::MAX_POST_BODY_BYTES,
        ))
}

/// Viewer route, merged into the protected threads router.
pub fn ws_router() -> Router<AppState> {
    Router::new().route("/api/threads/:id/browser/ws", get(ws_handler))
}

/// How often the socket re-checks for a feed that does not exist yet: a
/// viewer who opens the panel before the agent first browses still sees
/// the first frame without reconnecting.
const FEED_POLL: Duration = Duration::from_millis(500);
/// Keepalive matching the terminal socket.
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
    State(state): State<AppState>,
    Extension(client_ip): Extension<ClientIp>,
    headers: HeaderMap,
    Json(post): Json<FeedPost>,
) -> Response {
    let token = bearer_token(&headers).unwrap_or("");
    let Some(feed) = state.browser_feeds.by_token(token) else {
        // A failed feed token pays the probe rate, same as machine tokens,
        // topped up from whatever classify() charged this request's shape.
        use crate::security::rate_limit::EndpointClass;
        let upfront = if bearer_token(&headers).is_some() {
            EndpointClass::BrowserFeed
        } else {
            EndpointClass::UnauthProbe
        }
        .cost();
        if !charge_auth_failure(&state.rate_limiter, client_ip.0.as_ref(), upfront).await {
            return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
        }
        return (
            StatusCode::UNAUTHORIZED,
            Json(ApiError::new("invalid feed token")),
        )
            .into_response();
    };
    feed.publish(post);
    StatusCode::NO_CONTENT.into_response()
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(thread_id): Path<String>,
) -> Response {
    let thread = match state.db.get_thread(&thread_id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    let node = match super::threads::plan::thread_target(&state, &thread).await {
        Ok(t) => t.node,
        Err(e) => return map_err_internal(e).into_response(),
    };

    ws.on_upgrade(move |socket| serve(socket, state, thread_id, node, user.username))
}

/// Serve one viewer: idle until the thread's feed exists, then forward
/// frames. For node threads the feed lives on the satellite, so the socket
/// tunnels onto `/api/node/browser-feed/ws` with the feed token.
async fn serve(
    mut socket: axum::extract::ws::WebSocket,
    state: AppState,
    thread_id: String,
    node: Option<crate::db::federation_nodes::FederationNodeRow>,
    username: String,
) {
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await; // first tick fires immediately; skip it
    let mut sent_idle = false;

    loop {
        let Some(feed) = state.browser_feeds.peek(&thread_id) else {
            if !sent_idle {
                sent_idle = true;
                if send_text(&mut socket, idle_message()).await.is_err() {
                    return;
                }
            }
            tokio::select! {
                msg = socket.recv() => {
                    match msg {
                        Some(Ok(axum::extract::ws::Message::Close(_))) | None => return,
                        Some(Err(_)) => return,
                        // Pings, pongs, and stray client messages are
                        // tolerated while waiting for the feed to appear.
                        _ => continue,
                    }
                }
                _ = ping.tick() => {
                    if socket.send(axum::extract::ws::Message::Ping(vec![])).await.is_err() {
                        return;
                    }
                }
                _ = tokio::time::sleep(FEED_POLL) => {}
            }
            continue;
        };

        if let Some(node) = &node {
            let Some(client) = crate::node_client::NodeClient::for_node(&state, node) else {
                // Node lost its credential: report idle rather than hang.
                let _ = send_text(&mut socket, idle_message()).await;
                return;
            };
            tunnel_node_feed(socket, client, feed.token.clone(), username).await;
            return;
        }

        return stream_local_feed(socket, feed).await;
    }
}

/// Forward a local feed to the viewer: the latest frame first, then live.
async fn stream_local_feed(
    mut socket: axum::extract::ws::WebSocket,
    feed: std::sync::Arc<crate::browser_feed::BrowserFeed>,
) {
    let mut rx = feed.subscribe();
    if let Some(latest) = feed.latest_message() {
        if send_text(&mut socket, latest).await.is_err() {
            return;
        }
    }
    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.tick().await;
    loop {
        tokio::select! {
            msg = socket.recv() => {
                match msg {
                    // The panel is view-only; client messages are ignored,
                    // but a close or a dead socket ends the stream.
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => return,
                    Some(Err(_)) => return,
                    _ => continue,
                }
            }
            frame = rx.recv() => {
                match frame {
                    Ok(text) => {
                        if send_text(&mut socket, text).await.is_err() {
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

/// Tunnel the viewer socket onto the node's feed WS for the same thread.
/// Satellite and hub speak the same frame/status JSON, so text passes
/// through untouched; the viewer never sends anything but close.
async fn tunnel_node_feed(
    mut socket: axum::extract::ws::WebSocket,
    client: crate::node_client::NodeClient,
    feed_token: String,
    username: String,
) {
    use futures::{SinkExt, StreamExt};

    let url = client.browser_feed_ws_url();
    let mut request =
        match tokio_tungstenite::tungstenite::client::IntoClientRequest::into_client_request(&url) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(error = %e, "invalid node feed ws url");
                return;
            }
        };
    let headers = request.headers_mut();
    let Ok(node_auth) = format!("Bearer {}", client.token()).parse() else {
        return;
    };
    headers.insert(header::AUTHORIZATION, node_auth);
    let Ok(feed_auth) = feed_token.parse() else {
        return;
    };
    headers.insert(crate::browser_feed::FEED_TOKEN_HEADER, feed_auth);
    if let Ok(user) = username.parse() {
        headers.insert(crate::federation::PROXY_USER_HEADER, user);
    }
    let (upstream, _) = match tokio_tungstenite::connect_async(request).await {
        Ok(u) => u,
        Err(e) => {
            tracing::warn!(error = %e, "node feed ws dial failed");
            let _ = send_text(&mut socket, idle_message()).await;
            return;
        }
    };
    let (mut up_tx, mut up_rx) = upstream.split();

    loop {
        tokio::select! {
            msg = socket.recv() => {
                match msg {
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => {
                        let _ = up_tx
                            .send(tokio_tungstenite::tungstenite::Message::Close(None))
                            .await;
                        return;
                    }
                    Some(Err(_)) => return,
                    Some(Ok(axum::extract::ws::Message::Ping(p))) => {
                        if up_tx
                            .send(tokio_tungstenite::tungstenite::Message::Ping(p))
                            .await
                            .is_err()
                        {
                            return;
                        }
                    }
                    _ => continue,
                }
            }
            msg = up_rx.next() => {
                let Some(msg) = msg else { return };
                let Ok(msg) = msg else { return };
                match msg {
                    tokio_tungstenite::tungstenite::Message::Text(t) => {
                        if send_text(&mut socket, t).await.is_err() {
                            return;
                        }
                    }
                    tokio_tungstenite::tungstenite::Message::Ping(p) => {
                        if socket
                            .send(axum::extract::ws::Message::Ping(p))
                            .await
                            .is_err()
                        {
                            return;
                        }
                    }
                    tokio_tungstenite::tungstenite::Message::Close(frame) => {
                        let _ = socket
                            .send(axum::extract::ws::Message::Close(frame.map(|f| {
                                axum::extract::ws::CloseFrame {
                                    code: f.code.into(),
                                    reason: f.reason,
                                }
                            })))
                            .await;
                        return;
                    }
                    _ => continue,
                }
            }
        }
    }
}

async fn send_text(
    socket: &mut axum::extract::ws::WebSocket,
    text: String,
) -> Result<(), axum::Error> {
    socket.send(axum::extract::ws::Message::Text(text)).await
}
