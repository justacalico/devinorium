//! Thread + chat API routes.
//!
//! A thread maps to a devin-cli session. The first `send` starts the session
//! (`provider.start`); subsequent sends continue it (`provider.send`). Every
//! user message and assistant reply is persisted in the `messages` table.

use std::convert::Infallible;
use std::path::PathBuf;
use std::time::Duration;

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio_stream::wrappers::UnboundedReceiverStream;
use uuid::Uuid;

use crate::auth::session::CurrentUser;
use crate::db::{MessageRow, NewMessage, NewThread, ThreadRow};
use crate::providers::{Attachment, SendOptions, StartRequest};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/threads", get(list).post(create))
        .route("/api/threads/:id", get(get_one).patch(rename).delete(delete))
        .route("/api/threads/:id/messages", get(list_messages))
        .route("/api/threads/:id/send", post(send))
        .route("/api/threads/:id/send/stream", post(send_stream))
        .route("/api/threads/:id/project", get(get_project_path))
}

#[derive(Debug, Serialize)]
pub struct ThreadOut {
    pub id: String,
    pub title: String,
    pub project_id: i64,
    pub thread_group_id: Option<i64>,
    pub devin_session_id: Option<String>,
    pub model: String,
    pub permission_mode: String,
    pub permissions: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl From<ThreadRow> for ThreadOut {
    fn from(t: ThreadRow) -> Self {
        Self {
            id: t.id,
            title: t.title,
            project_id: t.project_id.unwrap_or(0),
            thread_group_id: t.thread_group_id,
            devin_session_id: t.devin_session_id,
            model: t.model,
            permission_mode: t.permission_mode,
            permissions: t.permissions,
            created_at: t.created_at,
            updated_at: t.updated_at,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct MessageOut {
    pub id: i64,
    pub role: String,
    pub content: String,
    pub attachments: serde_json::Value,
    pub created_at: String,
}

impl From<MessageRow> for MessageOut {
    fn from(m: MessageRow) -> Self {
        let attachments: serde_json::Value =
            serde_json::from_str(&m.attachments).unwrap_or(serde_json::json!([]));
        Self {
            id: m.id,
            role: m.role,
            content: m.content,
            attachments,
            created_at: m.created_at,
        }
    }
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.list_threads(user.id).await {
        Ok(rows) => Json(rows.into_iter().map(ThreadOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateThread {
    pub project_id: i64,
    pub title: Option<String>,
    pub thread_group_id: Option<i64>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    pub permissions: Option<String>,
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateThread>,
) -> Response {
    // Validate project ownership.
    match state.db.get_project(req.project_id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("invalid project_id"))).into_response();
        }
    }

    // Validate group ownership if provided.
    if let Some(gid) = req.thread_group_id {
        match state.db.get_thread_group(gid, user.id).await {
            Ok(Some(_)) => {}
            _ => {
                return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("invalid thread_group_id"))).into_response();
            }
        }
    }
    let permission_mode = req.permission_mode.unwrap_or_else(|| "normal".into());
    if !["normal", "accept-edits", "smart", "bypass"].contains(&permission_mode.as_str()) {
        return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("invalid permission_mode"))).into_response();
    }
    let new = NewThread {
        id: Uuid::new_v4().to_string(),
        user_id: user.id,
        project_id: req.project_id,
        thread_group_id: req.thread_group_id,
        title: req.title.unwrap_or_else(|| "New thread".into()),
        model: req.model.unwrap_or_else(|| state.config.default_model.clone()),
        permission_mode,
        permissions: req.permissions,
    };
    match state.db.create_thread(new).await {
        Ok(t) => (StatusCode::CREATED, Json(ThreadOut::from(t))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => {
            let messages = state.db.list_messages(&id).await.unwrap_or_default();
            Json(serde_json::json!({
                "thread": ThreadOut::from(t),
                "messages": messages.into_iter().map(MessageOut::from).collect::<Vec<_>>(),
            }))
            .into_response()
        }
        Ok(None) => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct UpdateThread {
    pub title: Option<String>,
    /// Distinguish between:
    ///   - field absent: don't change group
    ///   - field null: ungroup (set thread_group_id to NULL)
    ///   - field is a number: move to that group
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    pub thread_group_id: Option<Option<i64>>,
    pub permission_mode: Option<String>,
    /// Distinguish between:
    ///   - field absent: don't change permissions
    ///   - field null: clear permissions
    ///   - field string: set permissions
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub permissions: Option<Option<String>>,
}

/// Custom deserializer that maps `null` → `Some(None)` and a number → `Some(Some(n))`.
/// With `#[serde(default)]`, an absent field → `None` (outer).
fn deserialize_optional_field<'de, D>(deserializer: D) -> Result<Option<Option<i64>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<i64>::deserialize(deserializer)?;
    Ok(Some(opt))
}

fn deserialize_optional_string<'de, D>(deserializer: D) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<String>::deserialize(deserializer)?;
    Ok(Some(opt))
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Json(req): Json<UpdateThread>,
) -> Response {
    // Update title if provided.
    if let Some(title) = &req.title {
        if title.trim().is_empty() || title.len() > 200 {
            return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("title must be 1-200 chars"))).into_response();
        }
        if let Err(e) = state.db.rename_thread(&id, user.id, title).await {
            return crate::api::map_err_internal(e).into_response();
        }
    }
    // Move to group if the field was present.
    if let Some(group_id) = req.thread_group_id {
        if let Err(e) = state.db.move_thread_to_group(&id, user.id, group_id).await {
            return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new(e.to_string()))).into_response();
        }
    }
    // Validate and apply permission mode changes.
    if let Some(mode) = &req.permission_mode {
        if !["normal", "accept-edits", "smart", "bypass"].contains(&mode.as_str()) {
            return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("invalid permission_mode"))).into_response();
        }
    }
    if req.permission_mode.is_some() || req.permissions.is_some() {
        // Treat an empty permissions string as a request to clear the field.
        let permissions = req
            .permissions
            .as_ref()
            .map(|opt| opt.as_deref().filter(|s| !s.trim().is_empty()));
        if let Err(e) = state.db.update_thread_settings(&id, user.id, req.permission_mode.as_deref(), permissions).await {
            return crate::api::map_err_internal(e).into_response();
        }
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.delete_thread(&id, user.id).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn list_messages(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    // Ensure the thread belongs to the user.
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        _ => return (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
    }
    match state.db.list_messages(&id).await {
        Ok(rows) => Json(rows.into_iter().map(MessageOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

/// Send a message to a thread. Multipart form: `prompt` (text, required),
/// optional file parts (attachments).
async fn send(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => return (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };

    let user_msg = match persist_user_message(&state, &id, &input.prompt, &input.att_meta).await {
        Ok(m) => m,
        Err(resp) => return resp,
    };

    let provider_result = call_provider(&state, &thread, &input.prompt, input.attachments).await;

    let (reply, new_session_id, new_title) = match provider_result {
        Ok(t) => t,
        Err(e) => {
            let _ = state
                .db
                .add_message(NewMessage {
                    thread_id: id.clone(),
                    role: "error".into(),
                    content: format!("provider error: {e}"),
                    attachments: "[]".into(),
                })
                .await;
            let _ = state.db.touch_thread(&id).await;
            return (StatusCode::BAD_GATEWAY, Json(crate::api::ApiError::new("provider error"))).into_response();
        }
    };

    let assistant_msg = match persist_assistant_reply(&state, &id, user.id, &reply, new_session_id, new_title).await {
        Ok(m) => m,
        Err(resp) => return resp,
    };

    Json(serde_json::json!({
        "user_message": MessageOut::from(user_msg),
        "assistant_message": MessageOut::from(assistant_msg),
        "reply": reply,
    }))
    .into_response()
}

/// Stream a message response as Server-Sent Events. Same multipart input as
/// `send`, but the assistant reply is emitted chunk by chunk so the UI can
/// render a streaming effect.
async fn send_stream(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Sse<UnboundedReceiverStream<Result<Event, Infallible>>> {
    let (tx, rx) = mpsc::unbounded_channel::<Result<Event, Infallible>>();

    tokio::spawn(async move {
        let send_event = |tx: &mpsc::UnboundedSender<Result<Event, Infallible>>, ev: Event| -> bool {
            tx.send(Ok(ev)).is_ok()
        };

        let thread = match state.db.get_thread(&id, user.id).await {
            Ok(Some(t)) => t,
            Ok(None) => {
                send_event(&tx, Event::default().event("error").data("not found"));
                return;
            }
            Err(e) => {
                send_event(&tx, Event::default().event("error").data(&format!("internal error: {e}")));
                return;
            }
        };

        let input = match parse_send_multipart(multipart).await {
            Ok(parsed) => parsed,
            Err(_) => {
                send_event(&tx, Event::default().event("error").data("invalid request"));
                return;
            }
        };

        let user_msg = match persist_user_message(&state, &id, &input.prompt, &input.att_meta).await {
            Ok(m) => m,
            Err(_) => {
                send_event(&tx, Event::default().event("error").data("failed to save user message"));
                return;
            }
        };
        if !send_event(&tx, Event::default().event("user_message").data(&match serde_json::to_string(&MessageOut::from(user_msg)) {
            Ok(json) => json,
            Err(_) => return,
        })) {
            return;
        }

        // Keep the SSE connection alive while devin CLI runs, since a long
        // tool call can leave the response idle and trigger proxy timeouts.
        let tx2 = tx.clone();
        let mut keepalive = tokio::time::interval(Duration::from_secs(10));
        keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let keepalive_handle = tokio::spawn(async move {
            // tokio::time::interval fires the first tick immediately.
            // Consume it so the loop then waits a full 10 s before each ping.
            keepalive.tick().await;
            loop {
                keepalive.tick().await;
                if tx2.send(Ok(Event::default().comment("keep-alive"))).is_err() {
                    break;
                }
            }
        });

        let provider_result = call_provider(&state, &thread, &input.prompt, input.attachments).await;
        keepalive_handle.abort();

        let (reply, new_session_id, new_title) = match provider_result {
            Ok(t) => t,
            Err(e) => {
                let _ = state
                    .db
                    .add_message(NewMessage {
                        thread_id: id.clone(),
                        role: "error".into(),
                        content: format!("provider error: {e}"),
                        attachments: "[]".into(),
                    })
                    .await;
                let _ = state.db.touch_thread(&id).await;
                send_event(&tx, Event::default().event("error").data("provider error"));
                return;
            }
        };

        // Stream the reply in small chunks to create a typing effect.
        let chars: Vec<char> = reply.chars().collect();
        for chunk in chars.chunks(4) {
            let text: String = chunk.iter().collect();
            if !send_event(&tx, Event::default().event("chunk").data(&text)) {
                return;
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(12)).await;
        }

        let assistant_msg = match persist_assistant_reply(&state, &id, user.id, &reply, new_session_id, new_title).await {
            Ok(m) => m,
            Err(_) => {
                send_event(&tx, Event::default().event("error").data("failed to save assistant message"));
                return;
            }
        };
        send_event(&tx, Event::default().event("done").data(&match serde_json::to_string(&MessageOut::from(assistant_msg)) {
            Ok(json) => json,
            Err(_) => return,
        }));
    });

    Sse::new(UnboundedReceiverStream::new(rx))
}

struct SendInput {
    prompt: String,
    attachments: Vec<Attachment>,
    att_meta: Vec<serde_json::Value>,
}

async fn parse_send_multipart(mut multipart: Multipart) -> Result<SendInput, Response> {
    let mut prompt: Option<String> = None;
    let mut attachments: Vec<Attachment> = Vec::new();
    let mut att_meta: Vec<serde_json::Value> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let mime = field.content_type().unwrap_or("application/octet-stream").to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
        };
        if name == "prompt" {
            prompt = Some(String::from_utf8_lossy(&bytes).to_string());
        } else if !filename.is_empty() {
            if bytes.len() > 8 * 1024 * 1024 {
                return Err((StatusCode::PAYLOAD_TOO_LARGE, Json(crate::api::ApiError::new("attachment too large (max 8 MiB)"))).into_response());
            }
            att_meta.push(serde_json::json!({
                "filename": filename,
                "mime": mime,
                "size": bytes.len(),
            }));
            attachments.push(Attachment {
                filename: filename.clone(),
                mime,
                data: bytes.to_vec(),
            });
        }
    }
    let prompt = match prompt {
        Some(p) if !p.trim().is_empty() => p,
        _ => return Err((StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("prompt is required"))).into_response()),
    };
    if prompt.len() > 64 * 1024 {
        return Err((StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("prompt too long (max 64 KiB)"))).into_response());
    }
    Ok(SendInput { prompt, attachments, att_meta })
}

async fn persist_user_message(
    state: &AppState,
    thread_id: &str,
    prompt: &str,
    att_meta: &[serde_json::Value],
) -> Result<MessageRow, Response> {
    state
        .db
        .add_message(NewMessage {
            thread_id: thread_id.into(),
            role: "user".into(),
            content: prompt.into(),
            attachments: serde_json::to_string(att_meta).unwrap_or_else(|_| "[]".into()),
        })
        .await
        .map_err(|e| crate::api::map_err_internal(e).into_response())
}

async fn call_provider(
    state: &AppState,
    thread: &ThreadRow,
    prompt: &str,
    attachments: Vec<Attachment>,
) -> anyhow::Result<(String, Option<String>, Option<String>)> {
    let working_dir = project_working_dir_for_thread(state, thread).await?;

    let options = SendOptions {
        model: thread.model.clone(),
        working_dir,
        permission_mode: thread.permission_mode.clone(),
        permissions: thread.permissions.clone(),
        attachments,
    };

    if let Some(sid) = thread.devin_session_id.as_ref() {
        state
            .provider
            .send(crate::providers::SendRequest {
                session_id: sid.clone(),
                prompt: prompt.into(),
                options,
            })
            .await
            .map(|r| (r.reply, None, None))
    } else {
        state
            .provider
            .start(StartRequest {
                prompt: prompt.into(),
                options,
            })
            .await
            .map(|r| (r.reply, Some(r.session_id), Some(r.title)))
    }
}

async fn persist_assistant_reply(
    state: &AppState,
    thread_id: &str,
    user_id: i64,
    reply: &str,
    new_session_id: Option<String>,
    new_title: Option<String>,
) -> Result<MessageRow, Response> {
    let session_id_for_audit = new_session_id.clone();
    if let Some(sid) = new_session_id {
        let _ = state.db.update_thread_session(thread_id, &sid, new_title.as_deref()).await;
    }
    let _ = state.db.touch_thread(thread_id).await;

    let assistant_msg = state
        .db
        .add_message(NewMessage {
            thread_id: thread_id.into(),
            role: "assistant".into(),
            content: reply.into(),
            attachments: "[]".into(),
        })
        .await
        .map_err(|e| crate::api::map_err_internal(e).into_response())?;

    let _ = state
        .db
        .audit(
            Some(user_id),
            "thread.send",
            &serde_json::json!({"thread_id": thread_id, "session_id": session_id_for_audit}),
            None,
        )
        .await;

    Ok(assistant_msg)
}

/// Return the filesystem working directory for a thread.
///
/// If the thread belongs to a project, use the project's canonical path.
/// Otherwise fall back to the configured global file root.
async fn project_working_dir_for_thread(
    state: &AppState,
    thread: &ThreadRow,
) -> anyhow::Result<PathBuf> {
    if let Some(pid) = thread.project_id {
        if let Ok(Some(p)) = state.db.get_project(pid, thread.user_id).await {
            return Ok(PathBuf::from(&p.path));
        }
    }
    Ok(state
        .config
        .file_root
        .clone()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))))
}

async fn get_project_path(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => match t.project_id {
            Some(pid) => match state.db.get_project(pid, user.id).await {
                Ok(Some(p)) => Json(serde_json::json!({
                    "project_id": p.id,
                    "path": p.path,
                    "name": p.name,
                }))
                .into_response(),
                _ => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("project not found"))).into_response(),
            },
            None => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("thread has no project"))).into_response(),
        },
        Ok(None) => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
