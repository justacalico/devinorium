//! Terminal WebSocket API.
//!
//! Spawns persistent backend PTY sessions and streams their I/O to the
//! Flutter frontend over a WebSocket. Terminal access is restricted to the
//! owner account because a PTY is full RCE on the backend host.

use std::time::Duration;

use axum::extract::{Path, State, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::terminal::session::{TerminalEvent, TerminalSession};
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct CreateTerminal {
    pub thread_id: String,
}

#[derive(Debug, Serialize)]
pub struct TerminalCreated {
    pub id: String,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/terminal/sessions", post(create))
        .route("/api/terminal/sessions/:id", delete(kill))
        .route("/api/terminal/sessions/:id/ws", get(ws_handler))
}

fn forbidden() -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(crate::api::ApiError::new("terminal access denied")),
    )
        .into_response()
}

fn owner_only(user: &crate::db::UserRow) -> bool {
    user.is_owner || user.role == "owner"
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateTerminal>,
) -> Response {
    if !owner_only(&user) {
        return forbidden();
    }

    let thread = match state.db.get_thread(&req.thread_id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid thread_id")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    match state
        .terminal_manager
        .spawn(user.id, thread.id.clone(), None)
        .await
    {
        Ok(session) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "terminal.create",
                    &serde_json::json!({
                        "thread_id": thread.id,
                        "terminal_id": session.id,
                    }),
                    None,
                )
                .await;
            (
                StatusCode::CREATED,
                Json(TerminalCreated {
                    id: session.id.clone(),
                }),
            )
                .into_response()
        }
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn kill(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    if !owner_only(&user) {
        return forbidden();
    }

    let session = match state.terminal_manager.get(&id).await {
        Some(s) => s,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
    };

    if session.user_id != user.id {
        return forbidden();
    }

    match state.terminal_manager.kill(&id).await {
        Ok(()) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "terminal.kill",
                    &serde_json::json!({
                        "terminal_id": id,
                    }),
                    None,
                )
                .await;
            Json(serde_json::json!({"ok": true})).into_response()
        }
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    if !owner_only(&user) {
        return forbidden();
    }

    let session = match state.terminal_manager.get(&id).await {
        Some(s) => s,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
    };

    if session.user_id != user.id {
        return forbidden();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "terminal.connect",
            &serde_json::json!({
                "terminal_id": id,
                "thread_id": session.thread_id,
            }),
            None,
        )
        .await;

    ws.on_upgrade(move |socket| handle_socket(socket, state, session))
}

async fn handle_socket(
    mut socket: axum::extract::ws::WebSocket,
    state: AppState,
    session: std::sync::Arc<TerminalSession>,
) {
    let mut rx = session.subscribe();

    // Send an initial resize so the PTY matches a default TerminalView size.
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
                    Some(Ok(axum::extract::ws::Message::Binary(_))) => {
                        // Binary frames from the client are reserved for future use.
                    }
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None => break,
                    Some(Err(e)) => {
                        tracing::debug!(error = %e, "websocket error");
                        break;
                    }
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

    let _ = state
        .db
        .audit(
            Some(session.user_id),
            "terminal.disconnect",
            &serde_json::json!({
                "terminal_id": session.id,
                "thread_id": session.thread_id,
            }),
            None,
        )
        .await;
}

async fn handle_client_message(session: &TerminalSession, text: &str) -> anyhow::Result<()> {
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
