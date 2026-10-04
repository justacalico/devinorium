//! Satellite terminal endpoints: PTY sessions tunneled from the hub.
//!
//! Same protocol as the hub's terminal API — binary frames out, JSON
//! input/resize/signal messages in — so the hub can relay a WebSocket
//! without translation.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Deserialize;

use crate::node::{CreateNodeTerminal, NodeError};
use crate::satellite::{internal, SatelliteState};
use crate::terminal::session::TerminalEvent;

pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new()
        .route("/api/node/terminal/sessions", post(create))
        .route("/api/node/terminal/sessions/:id", delete(kill))
        .route("/api/node/terminal/sessions/:id/ws", get(ws_handler))
}

async fn create(
    State(state): State<Arc<SatelliteState>>,
    Json(req): Json<CreateNodeTerminal>,
) -> Response {
    match state
        .terminal_manager
        .spawn(0, req.thread_id, None, Some(req.cwd))
        .await
    {
        Ok(session) => (
            StatusCode::CREATED,
            Json(serde_json::json!({"id": session.id})),
        )
            .into_response(),
        Err(e) => internal(e).into_response(),
    }
}

async fn kill(State(state): State<Arc<SatelliteState>>, Path(id): Path<String>) -> Response {
    if state.terminal_manager.get(&id).await.is_none() {
        return (
            StatusCode::NOT_FOUND,
            Json(NodeError::new("not_found", "no such session")),
        )
            .into_response();
    }
    match state.terminal_manager.kill(&id).await {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => internal(e).into_response(),
    }
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<SatelliteState>>,
    Path(id): Path<String>,
) -> Response {
    let session = match state.terminal_manager.get(&id).await {
        Some(s) => s,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(NodeError::new("not_found", "no such session")),
            )
                .into_response();
        }
    };
    ws.on_upgrade(move |socket| handle_socket(socket, session))
}

async fn handle_socket(
    mut socket: axum::extract::ws::WebSocket,
    session: Arc<crate::terminal::session::TerminalSession>,
) {
    let mut rx = session.subscribe();
    let _ = session.resize(80, 24);
    let mut ping_interval = tokio::time::interval(Duration::from_secs(30));

    loop {
        tokio::select! {
            msg = socket.recv() => {
                match msg {
                    Some(Ok(axum::extract::ws::Message::Text(text))) => {
                        if let Err(e) = handle_client_message(&session, &text).await {
                            tracing::debug!(error = %e, "terminal message error");
                        }
                    }
                    Some(Ok(axum::extract::ws::Message::Binary(_))) => {}
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => break,
                    Some(Err(_)) => break,
                    _ => {}
                }
            }
            event = rx.recv() => {
                match event {
                    Ok(TerminalEvent::Output(bytes)) => {
                        if socket.send(axum::extract::ws::Message::Binary(bytes)).await.is_err() {
                            break;
                        }
                    }
                    Ok(TerminalEvent::Exited(code)) => {
                        let payload = serde_json::json!({"type": "exited", "code": code});
                        let _ = socket.send(axum::extract::ws::Message::Text(payload.to_string())).await;
                        break;
                    }
                    Err(_) => break,
                }
            }
            _ = ping_interval.tick() => {
                if socket.send(axum::extract::ws::Message::Ping(vec![])).await.is_err() {
                    break;
                }
            }
        }
    }
}

async fn handle_client_message(
    session: &crate::terminal::session::TerminalSession,
    text: &str,
) -> anyhow::Result<()> {
    let msg: ClientMessage = serde_json::from_str(text)?;
    match msg {
        ClientMessage::Input { data } => session.write_input(&data)?,
        ClientMessage::Resize { cols, rows } => session.resize(cols, rows)?,
        ClientMessage::Signal { sig } => session.send_signal(&sig)?,
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMessage {
    Input { data: String },
    Resize { cols: u16, rows: u16 },
    Signal { sig: String },
}
