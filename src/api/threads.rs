//! Thread + chat API routes.
//!
//! A thread maps to a devin-cli session. The first `send` starts the session
//! (`provider.start`); subsequent sends continue it (`provider.send`). Every
//! user message and assistant reply is persisted in the `messages` table.

use std::path::PathBuf;

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};
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
}

#[derive(Debug, Serialize)]
pub struct ThreadOut {
    pub id: String,
    pub title: String,
    pub workspace_id: Option<i64>,
    pub devin_session_id: Option<String>,
    pub model: String,
    pub permission_mode: String,
    pub created_at: String,
    pub updated_at: String,
}

impl From<ThreadRow> for ThreadOut {
    fn from(t: ThreadRow) -> Self {
        Self {
            id: t.id,
            title: t.title,
            workspace_id: t.workspace_id,
            devin_session_id: t.devin_session_id,
            model: t.model,
            permission_mode: t.permission_mode,
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
    pub title: Option<String>,
    pub workspace_id: Option<i64>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateThread>,
) -> Response {
    // Validate workspace ownership if provided.
    if let Some(wid) = req.workspace_id {
        match state.db.get_workspace(wid, user.id).await {
            Ok(Some(_)) => {}
            _ => {
                return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("invalid workspace"))).into_response();
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
        workspace_id: req.workspace_id,
        title: req.title.unwrap_or_else(|| "New thread".into()),
        model: req.model.unwrap_or_else(|| state.config.default_model.clone()),
        permission_mode,
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
pub struct RenameThread {
    pub title: String,
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Json(req): Json<RenameThread>,
) -> Response {
    if req.title.trim().is_empty() || req.title.len() > 200 {
        return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("title must be 1-200 chars"))).into_response();
    }
    match state.db.rename_thread(&id, user.id, &req.title).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
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
    mut multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => return (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    // Parse multipart: collect prompt + attachments.
    let mut prompt: Option<String> = None;
    let mut attachments: Vec<Attachment> = Vec::new();
    let mut att_meta: Vec<serde_json::Value> = Vec::new();
    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let mime = field.content_type().unwrap_or("application/octet-stream").to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        };
        if name == "prompt" {
            prompt = Some(String::from_utf8_lossy(&bytes).to_string());
        } else if !filename.is_empty() {
            // Limit individual attachment size to 8 MiB.
            if bytes.len() > 8 * 1024 * 1024 {
                return (StatusCode::PAYLOAD_TOO_LARGE, Json(crate::api::ApiError::new("attachment too large (max 8 MiB)"))).into_response();
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
        _ => return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("prompt is required"))).into_response(),
    };
    if prompt.len() > 64 * 1024 {
        return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("prompt too long (max 64 KiB)"))).into_response();
    }

    // Determine working directory from the thread's workspace.
    let working_dir = match thread.workspace_id {
        Some(wid) => match state.db.get_workspace(wid, user.id).await {
            Ok(Some(w)) => PathBuf::from(&w.path),
            _ => return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("workspace missing"))).into_response(),
        },
        None => std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    };

    // Persist the user message.
    let user_msg = match state
        .db
        .add_message(NewMessage {
            thread_id: id.clone(),
            role: "user".into(),
            content: prompt.clone(),
            attachments: serde_json::to_string(&att_meta).unwrap_or_else(|_| "[]".into()),
        })
        .await
    {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let options = SendOptions {
        model: thread.model.clone(),
        working_dir: working_dir.clone(),
        permission_mode: thread.permission_mode.clone(),
        attachments,
    };

    // Call the provider. First message starts a session; subsequent messages
    // continue it. Both branches are normalized into (reply, session_id, title).
    let provider_result: anyhow::Result<(String, Option<String>, Option<String>)> =
        if let Some(sid) = thread.devin_session_id.as_ref() {
            match state
                .provider
                .send(crate::providers::SendRequest {
                    session_id: sid.clone(),
                    prompt: prompt.clone(),
                    options,
                })
                .await
            {
                Ok(r) => Ok((r.reply, None, None)),
                Err(e) => Err(e),
            }
        } else {
            match state
                .provider
                .start(StartRequest {
                    prompt: prompt.clone(),
                    options,
                })
                .await
            {
                Ok(r) => Ok((r.reply, Some(r.session_id), Some(r.title))),
                Err(e) => Err(e),
            }
        };

    let (reply, new_session_id, new_title) = match provider_result {
        Ok(t) => t,
        Err(e) => {
            // Record an error message so the user sees what happened.
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

    // Update the thread with the session id / title if first message.
    let session_id_for_audit = new_session_id.clone();
    if let Some(sid) = new_session_id {
        let _ = state.db.update_thread_session(&id, &sid, new_title.as_deref()).await;
    }
    let _ = state.db.touch_thread(&id).await;

    // Persist the assistant message.
    let assistant_msg = match state
        .db
        .add_message(NewMessage {
            thread_id: id.clone(),
            role: "assistant".into(),
            content: reply.clone(),
            attachments: "[]".into(),
        })
        .await
    {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let _ = state
        .db
        .audit(
            Some(user.id),
            "thread.send",
            &serde_json::json!({"thread_id": id, "session_id": session_id_for_audit}),
            None,
        )
        .await;

    Json(serde_json::json!({
        "user_message": MessageOut::from(user_msg),
        "assistant_message": MessageOut::from(assistant_msg),
        "reply": reply,
    }))
    .into_response()
}
