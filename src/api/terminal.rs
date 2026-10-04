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
    /// Optional thread the session is associated with. Terminals are global
    /// in the UI, so a session may be created without an active thread.
    #[serde(default)]
    pub thread_id: Option<String>,
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

/// Look up the node hosting a remote session. Keys are `node_id:session_id`
/// so ids from different satellites cannot collide; lookup is by suffix
/// since the client only carries the session id.
fn remote_node_for(
    state: &AppState,
    session_id: &str,
) -> Option<crate::db::federation_nodes::FederationNodeRow> {
    let suffix = format!(":{session_id}");
    state
        .remote_terminals
        .lock()
        .unwrap()
        .iter()
        .find(|(k, _)| k.ends_with(&suffix))
        .map(|(_, n)| n.clone())
}

fn drop_remote_node(state: &AppState, node_id: &str, session_id: &str) {
    state
        .remote_terminals
        .lock()
        .unwrap()
        .remove(&format!("{node_id}:{session_id}"));
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateTerminal>,
) -> Response {
    if !owner_only(&user) {
        return forbidden();
    }

    let (thread_id, cwd, remote) = match req.thread_id.as_deref().filter(|t| !t.is_empty()) {
        Some(thread_id) => match state.db.get_thread(thread_id, user.id).await {
            Ok(Some(t)) => {
                // Open the shell where the thread's files are: its managed
                // worktree when it runs in one, else the project checkout.
                // A node-bound thread keeps the PTY on the satellite.
                let target = match super::threads::plan::thread_target(&state, &t).await {
                    Ok(target) => target,
                    Err(e) => return crate::api::map_err_internal(e).into_response(),
                };
                let remote = match &target.node {
                    Some(node) => match crate::node_client::NodeClient::for_node(&state, node) {
                        Some(client) => {
                            Some((client.with_proxy_user(&user.username), node.clone()))
                        }
                        None => return crate::node_client::node_bad_gateway("node unreachable"),
                    },
                    None => None,
                };
                (t.id, target.dir, remote)
            }
            Ok(None) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid thread_id")),
                )
                    .into_response();
            }
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        },
        None => (String::new(), state.config.home_dir.clone(), None),
    };

    if let Some((client, node)) = remote {
        // The PTY lives on the node; the hub remembers which node owns the
        // session so the WS route below can tunnel into it. The key is
        // node-scoped so ids from different satellites cannot collide.
        return match client.create_terminal(&cwd, &thread_id).await {
            Ok(id) => {
                state
                    .remote_terminals
                    .lock()
                    .unwrap()
                    .insert(format!("{}:{}", node.id, id), node);
                (StatusCode::CREATED, Json(TerminalCreated { id })).into_response()
            }
            Err(e) => crate::node_client::node_bad_gateway(e.to_string()),
        };
    }

    match state
        .terminal_manager
        .spawn(user.id, thread_id.clone(), None, Some(cwd))
        .await
    {
        Ok(session) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "terminal.create",
                    &serde_json::json!({
                        "thread_id": thread_id,
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

    // A session the node created gets killed on the node.
    let remote_node = remote_node_for(&state, &id);
    if let Some(node) = remote_node {
        let Some(client) = crate::node_client::NodeClient::for_node(&state, &node) else {
            return crate::node_client::node_bad_gateway("node unreachable");
        };
        match client
            .with_proxy_user(&user.username)
            .delete_terminal(&id)
            .await
        {
            Ok(()) => {
                drop_remote_node(&state, &node.id, &id);
                return Json(serde_json::json!({"ok": true})).into_response();
            }
            // Already dead on the satellite: clear the local record so the
            // id stops 502ing.
            Err(crate::node_client::NodeCallError::Remote { ref kind, .. })
                if kind == "not_found" || kind == "404" =>
            {
                drop_remote_node(&state, &node.id, &id);
                return Json(serde_json::json!({"ok": true})).into_response();
            }
            Err(e) => return crate::node_client::node_bad_gateway(e.to_string()),
        }
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

    // A session the node created is tunneled through to it, authenticating
    // with the node token the same way the HTTP calls do.
    let remote_node = remote_node_for(&state, &id);
    if let Some(node) = remote_node {
        let Some(client) = crate::node_client::NodeClient::for_node(&state, &node) else {
            return crate::node_client::node_bad_gateway("node unreachable");
        };
        return ws.on_upgrade(move |socket| {
            tunnel_remote(socket, client.with_proxy_user(&user.username), id)
        });
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

/// Relay a hub WebSocket onto the node's terminal WS. Protocol frames
/// pass through verbatim — the node speaks the same binary-output /
/// JSON-input protocol as the local terminal.
async fn tunnel_remote(
    mut socket: axum::extract::ws::WebSocket,
    client: crate::node_client::NodeClient,
    session_id: String,
) {
    use futures::{SinkExt, StreamExt};

    let url = client.terminal_ws_url(&session_id);
    let mut request =
        match tokio_tungstenite::tungstenite::client::IntoClientRequest::into_client_request(&url) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(error = %e, "invalid node ws url");
                return;
            }
        };
    request.headers_mut().insert(
        axum::http::header::AUTHORIZATION,
        match format!("Bearer {}", client.token()).parse() {
            Ok(v) => v,
            Err(_) => return,
        },
    );
    let (upstream, _) = match tokio_tungstenite::connect_async(request).await {
        Ok(u) => u,
        Err(e) => {
            tracing::warn!(error = %e, "node terminal ws dial failed");
            let _ = socket
                .send(axum::extract::ws::Message::Text(
                    serde_json::json!({"type": "exited", "code": 1}).to_string(),
                ))
                .await;
            return;
        }
    };
    let (mut up_tx, mut up_rx) = upstream.split();

    loop {
        tokio::select! {
            msg = socket.recv() => {
                let Some(msg) = msg else { break };
                let Ok(msg) = msg else { break };
                let out = match msg {
                    axum::extract::ws::Message::Text(t) => {
                        tokio_tungstenite::tungstenite::Message::Text(t)
                    }
                    axum::extract::ws::Message::Binary(b) => {
                        tokio_tungstenite::tungstenite::Message::Binary(b)
                    }
                    axum::extract::ws::Message::Ping(p) => {
                        tokio_tungstenite::tungstenite::Message::Ping(p)
                    }
                    axum::extract::ws::Message::Pong(p) => {
                        tokio_tungstenite::tungstenite::Message::Pong(p)
                    }
                    axum::extract::ws::Message::Close(_) => {
                        let _ = up_tx
                            .send(tokio_tungstenite::tungstenite::Message::Close(None))
                            .await;
                        break;
                    }
                };
                if up_tx.send(out).await.is_err() {
                    break;
                }
            }
            msg = up_rx.next() => {
                let Some(msg) = msg else { break };
                let Ok(msg) = msg else { break };
                let out = match msg {
                    tokio_tungstenite::tungstenite::Message::Text(t) => {
                        axum::extract::ws::Message::Text(t)
                    }
                    tokio_tungstenite::tungstenite::Message::Binary(b) => {
                        axum::extract::ws::Message::Binary(b)
                    }
                    tokio_tungstenite::tungstenite::Message::Ping(p) => {
                        axum::extract::ws::Message::Ping(p)
                    }
                    tokio_tungstenite::tungstenite::Message::Pong(p) => {
                        axum::extract::ws::Message::Pong(p)
                    }
                    tokio_tungstenite::tungstenite::Message::Close(_) => {
                        let _ = socket
                            .send(axum::extract::ws::Message::Close(None))
                            .await;
                        break;
                    }
                    _ => continue,
                };
                if socket.send(out).await.is_err() {
                    break;
                }
            }
        }
    }
}
