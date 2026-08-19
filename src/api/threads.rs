//! Thread + chat API routes.
//!
//! A thread maps to a devin-cli session. The first `send` starts the session
//! (`provider.start`); subsequent sends continue it (`provider.send`). Every
//! user message and assistant reply is persisted in the `messages` table.

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Multipart, Path, Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use futures::stream::{BoxStream, StreamExt as FuturesStreamExt};
use serde::{Deserialize, Serialize};
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt as TokioStreamExt;
use uuid::Uuid;

use crate::auth::session::CurrentUser;
use crate::db::{MessageRow, NewMessage, NewThread, ThreadRow};
use crate::providers::{
    collect_text, collect_thinking, AskCallback, AskOutcome, AskRequest, Attachment, MessagePart,
    PartCallback, PartEvent, PermissionCallback, PermissionOutcome, PermissionRequest, SendOptions,
    StartRequest,
};
use crate::thread_runner::{RunState, RunStatus};
use crate::{AppState, PendingAskRequest, PendingPermissionRequest};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/threads", get(list).post(create))
        .route(
            "/api/threads/:id",
            get(get_one).patch(rename).delete(delete),
        )
        .route("/api/threads/:id/messages", get(list_messages))
        .route("/api/threads/:id/send", post(send))
        .route("/api/threads/:id/send/stream", post(send_stream))
        .route("/api/threads/:id/run", get(get_run))
        .route("/api/threads/:id/stop", post(stop))
        .route("/api/threads/:id/events", get(events))
        .route(
            "/api/threads/:id/permission/:request_id",
            post(respond_permission),
        )
        .route("/api/threads/:id/ask/:request_id", post(respond_ask))
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
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
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
            branch: t.branch,
            worktree_path: t.worktree_path,
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
    pub thinking: Option<String>,
    pub parts: Vec<MessagePart>,
    pub attachments: serde_json::Value,
    pub created_at: String,
}

impl From<MessageRow> for MessageOut {
    fn from(m: MessageRow) -> Self {
        let attachments: serde_json::Value =
            serde_json::from_str(&m.attachments).unwrap_or(serde_json::json!([]));
        let parts: Vec<MessagePart> = m
            .parts
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_else(|| {
                let mut ps = vec![MessagePart::text(m.content.as_str())];
                if let Some(t) = m.thinking.as_deref().filter(|s| !s.is_empty()) {
                    ps.push(MessagePart::thinking(t));
                }
                ps
            });
        let content = collect_text(&parts);
        let thinking = collect_thinking(&parts);
        let thinking = (!thinking.is_empty()).then_some(thinking);
        Self {
            id: m.id,
            role: m.role,
            content,
            thinking,
            parts,
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
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
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
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project_id")),
            )
                .into_response();
        }
    }

    // Validate group ownership if provided.
    if let Some(gid) = req.thread_group_id {
        match state.db.get_thread_group(gid, user.id).await {
            Ok(Some(_)) => {}
            _ => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid thread_group_id")),
                )
                    .into_response();
            }
        }
    }
    let permission_mode = req.permission_mode.unwrap_or_else(|| "normal".into());
    if !["normal", "accept-edits", "smart", "bypass"].contains(&permission_mode.as_str()) {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid permission_mode")),
        )
            .into_response();
    }
    let model = req
        .model
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .unwrap_or_else(|| state.config.default_model.clone());
    if model.is_empty() || model.len() > 100 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("model must be 1-100 chars")),
        )
            .into_response();
    }
    let new = NewThread {
        id: Uuid::new_v4().to_string(),
        user_id: user.id,
        project_id: req.project_id,
        thread_group_id: req.thread_group_id,
        title: req.title.unwrap_or_else(|| "New thread".into()),
        model,
        permission_mode,
        permissions: req.permissions,
        branch: req.branch,
        worktree_path: req.worktree_path,
    };
    match state.db.create_thread(new).await {
        Ok(t) => (StatusCode::CREATED, Json(ThreadOut::from(t))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct GetThread {
    pub include_messages: Option<String>,
    pub limit: Option<i64>,
}

impl Default for GetThread {
    fn default() -> Self {
        Self {
            include_messages: None,
            limit: Some(50),
        }
    }
}

fn truthy(value: &str) -> bool {
    matches!(value, "true" | "1" | "yes" | "on")
}

async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Query(query): Query<GetThread>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => {
            let total = state.db.count_messages(&id).await.unwrap_or(0);
            let mut messages = Vec::new();
            if query.include_messages.as_deref().map_or(false, truthy) {
                let limit = query.limit.unwrap_or(50).clamp(1, 200);
                match state.db.list_messages_paginated(&id, None, None, limit).await {
                    Ok(rows) => {
                        messages = rows.into_iter().map(MessageOut::from).collect::<Vec<_>>();
                    }
                    Err(e) => return crate::api::map_err_internal(e).into_response(),
                }
            }
            Json(serde_json::json!({
                "thread": ThreadOut::from(t),
                "total_messages": total,
                "messages": messages,
            }))
            .into_response()
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
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
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    /// Distinguish between:
    ///   - field absent: don't change permissions
    ///   - field null: clear permissions
    ///   - field string: set permissions
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub permissions: Option<Option<String>>,
    /// Distinguish between absent and null for optional Git context.
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub branch: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub worktree_path: Option<Option<String>>,
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
    // Validate all inputs before touching the database.
    if let Some(title) = &req.title {
        if title.trim().is_empty() || title.len() > 200 {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("title must be 1-200 chars")),
            )
                .into_response();
        }
    }
    if let Some(mode) = &req.permission_mode {
        if !["normal", "accept-edits", "smart", "bypass"].contains(&mode.as_str()) {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid permission_mode")),
            )
                .into_response();
        }
    }
    if let Some(model) = &req.model {
        if model.trim().is_empty() || model.len() > 100 {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("model must be 1-100 chars")),
            )
                .into_response();
        }
    }

    // Apply updates.
    if let Some(title) = &req.title {
        if let Err(e) = state.db.rename_thread(&id, user.id, title).await {
            return crate::api::map_err_internal(e).into_response();
        }
    }
    if let Some(group_id) = req.thread_group_id {
        if let Err(e) = state.db.move_thread_to_group(&id, user.id, group_id).await {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(e.to_string())),
            )
                .into_response();
        }
    }
    if req.model.is_some() || req.permission_mode.is_some() || req.permissions.is_some() {
        // Treat an empty permissions string as a request to clear the field.
        let permissions = req
            .permissions
            .as_ref()
            .map(|opt| opt.as_deref().filter(|s| !s.trim().is_empty()));
        let model = req
            .model
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Err(e) = state
            .db
            .update_thread_settings(
                &id,
                user.id,
                model,
                req.permission_mode.as_deref(),
                permissions,
            )
            .await
        {
            return crate::api::map_err_internal(e).into_response();
        }
    }

    if req.branch.is_some() || req.worktree_path.is_some() {
        let branch = req
            .branch
            .as_ref()
            .and_then(|opt| opt.as_deref().filter(|s| !s.trim().is_empty()));
        let worktree_path = req
            .worktree_path
            .as_ref()
            .and_then(|opt| opt.as_deref().filter(|s| !s.trim().is_empty()));
        if let Err(e) = state
            .db
            .update_thread_git(&id, user.id, branch, worktree_path)
            .await
        {
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

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct ListMessages {
    pub before_id: Option<i64>,
    pub after_id: Option<i64>,
    pub limit: Option<i64>,
}

impl Default for ListMessages {
    fn default() -> Self {
        Self {
            before_id: None,
            after_id: None,
            limit: Some(50),
        }
    }
}

async fn list_messages(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Query(query): Query<ListMessages>,
) -> Response {
    // Ensure the thread belongs to the user.
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
    }

    if query.before_id.is_some() && query.after_id.is_some() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("before_id and after_id cannot both be set")),
        )
            .into_response();
    }

    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    match state
        .db
        .list_messages_paginated(&id, query.before_id, query.after_id, limit)
        .await
    {
        Ok(rows) => Json(serde_json::json!({
            "messages": rows.into_iter().map(MessageOut::from).collect::<Vec<_>>(),
            "total": state.db.count_messages(&id).await.unwrap_or(0),
            "limit": limit,
        }))
        .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

/// Get the current run status for a thread. Returns the active or most recent
/// run, or `{"status":"idle"}` if the thread has no run in memory.
async fn get_run(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    match state.thread_runner.get(&id).await {
        Some(run) => Json(run.snapshot().await).into_response(),
        None => Json(serde_json::json!({
            "run_id": null,
            "thread_id": id,
            "status": RunStatus::Idle.to_string(),
            "started_at": null,
            "updated_at": null,
            "error": null,
            "text": "",
            "thinking": "",
            "thinking_active": false,
            "parts": [],
            "tool_calls": [],
            "permission_request": null,
            "ask_request": null,
            "last_seq": 0,
        }))
        .into_response(),
    }
}

/// Stop the currently running model/ACP session for a thread.
async fn stop(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    match state.thread_runner.stop(&id).await {
        Some(snapshot) => Json(snapshot).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("no active run")),
        )
            .into_response(),
    }
}

/// Subscribe to the events of the current run as an SSE stream. Reconnecting
/// clients can resume watching a long-running thread without sending a new
/// message.
async fn events(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    match state.thread_runner.get(&id).await {
        Some(run) => events_stream(run).await.into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("no active run")),
        )
            .into_response(),
    }
}

/// Send a message to a thread. Multipart form: `prompt` (text, required),
/// optional file parts (attachments). The provider runs in the background so
/// the work continues even if the client disconnects.
async fn send(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };

    let user_msg = match persist_user_message(&state, &thread, &input).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let run = match state
        .thread_runner
        .start(id.clone(), {
            let state = state.clone();
            move |run| run_thread(state, run, user, thread, input, user_msg)
        })
        .await
    {
        Ok(run) => run,
        Err(crate::thread_runner::StartError::AlreadyRunning) => {
            return (
                StatusCode::CONFLICT,
                Json(crate::api::ApiError::new("thread is already running")),
            )
                .into_response();
        }
    };

    let mut rx = match run.subscribe() {
        Some(rx) => rx,
        None => {
            // The run finished before we could subscribe. Return the final
            // result based on the run status and any persisted messages.
            let status = *run.status.read().await;
            return match status {
                RunStatus::Stopped => Json(serde_json::json!({ "stopped": true })).into_response(),
                RunStatus::Completed => {
                    let messages = state.db.list_messages(&id).await.unwrap_or_default();
                    if let Some(reply) = build_send_reply(&messages) {
                        return reply;
                    }
                    (
                        StatusCode::BAD_GATEWAY,
                        Json(crate::api::ApiError::new("provider error")),
                    )
                        .into_response()
                }
                RunStatus::Failed => {
                    let error = run
                        .error
                        .read()
                        .await
                        .clone()
                        .unwrap_or_else(|| "provider error".into());
                    (
                        StatusCode::BAD_GATEWAY,
                        Json(crate::api::ApiError::new(&error)),
                    )
                        .into_response()
                }
                RunStatus::Running | RunStatus::Idle => (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(crate::api::ApiError::new("run already closed")),
                )
                    .into_response(),
            };
        }
    };
    let mut stopped = false;
    let mut permission_request = None;
    let mut ask_request = None;
    loop {
        match tokio::time::timeout(Duration::from_secs(30 * 60), rx.recv()).await {
            Ok(Ok(crate::thread_runner::RunEvent { event, .. })) if event == "done" => break,
            Ok(Ok(crate::thread_runner::RunEvent { event, .. })) if event == "stopped" => {
                stopped = true;
                break;
            }
            Ok(Ok(crate::thread_runner::RunEvent { event, data, .. })) if event == "error" => {
                return (
                    StatusCode::BAD_GATEWAY,
                    Json(crate::api::ApiError::new(&data)),
                )
                    .into_response();
            }
            Ok(Ok(crate::thread_runner::RunEvent { event, data, .. }))
                if event == "permission_request" =>
            {
                permission_request = Some(data);
                break;
            }
            Ok(Ok(crate::thread_runner::RunEvent { event, data, .. }))
                if event == "ask_request" =>
            {
                ask_request = Some(data);
                break;
            }
            Ok(Ok(_)) => continue,
            Ok(Err(_)) => break,
            Err(_) => {
                return (
                    StatusCode::GATEWAY_TIMEOUT,
                    Json(crate::api::ApiError::new("run did not finish in time")),
                )
                    .into_response();
            }
        }
    }

    if stopped {
        return Json(serde_json::json!({ "stopped": true })).into_response();
    }

    let status = *run.status.read().await;
    if status == RunStatus::Stopped {
        return Json(serde_json::json!({ "stopped": true })).into_response();
    }

    if let Some(data) = permission_request {
        return (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({ "permission_request": data })),
        )
            .into_response();
    }

    if let Some(data) = ask_request {
        return (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({ "ask_request": data })),
        )
            .into_response();
    }

    let messages = state.db.list_messages(&id).await.unwrap_or_default();
    if let Some(reply) = build_send_reply(&messages) {
        return reply;
    }

    (
        StatusCode::BAD_GATEWAY,
        Json(crate::api::ApiError::new("provider error")),
    )
        .into_response()
}

fn build_send_reply(messages: &[MessageRow]) -> Option<Response> {
    if messages.len() < 2 {
        return None;
    }
    let user_msg = &messages[messages.len() - 2];
    let assistant_msg = &messages[messages.len() - 1];
    if user_msg.role != "user" || assistant_msg.role != "assistant" {
        return None;
    }
    Some(
        Json(serde_json::json!({
            "user_message": MessageOut::from(user_msg.clone()),
            "assistant_message": MessageOut::from(assistant_msg.clone()),
            "reply": assistant_msg.content,
            "thinking": assistant_msg.thinking,
        }))
        .into_response(),
    )
}

fn sanitize_sse_data(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n")
}

/// Stream a message response as Server-Sent Events. The provider call starts
/// in the background and outlives this HTTP connection, so the thread keeps
/// running even if the client disconnects.
async fn send_stream(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };

    let user_msg = match persist_user_message(&state, &thread, &input).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let run = match state
        .thread_runner
        .start(id.clone(), {
            let state = state.clone();
            move |run| run_thread(state, run, user, thread, input, user_msg)
        })
        .await
    {
        Ok(run) => run,
        Err(crate::thread_runner::StartError::AlreadyRunning) => {
            return (
                StatusCode::CONFLICT,
                Json(crate::api::ApiError::new("thread is already running")),
            )
                .into_response();
        }
    };

    events_stream(run).await.into_response()
}

async fn events_stream(
    run: Arc<RunState>,
) -> Sse<BoxStream<'static, Result<Event, std::convert::Infallible>>> {
    // Subscribe first so events emitted while the snapshot is being built are
    // captured in the live stream and not lost.
    let live: BoxStream<'static, Result<Event, std::convert::Infallible>> = match run.subscribe() {
        Some(receiver) => FuturesStreamExt::boxed(TokioStreamExt::filter_map(
            BroadcastStream::new(receiver),
            |res| match res {
                Ok(ev) => {
                    let data = if ev.event == "error" {
                        sanitize_sse_data(&ev.data)
                    } else {
                        ev.data
                    };
                    Some(Ok::<_, std::convert::Infallible>(
                        Event::default()
                            .event(&ev.event)
                            .id(ev.seq.to_string())
                            .data(data),
                    ))
                }
                Err(_) => None,
            },
        )),
        None => FuturesStreamExt::boxed(tokio_stream::empty()),
    };

    let snapshot = run.snapshot().await;
    let state_json = serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string());
    let state_event =
        Ok::<_, std::convert::Infallible>(Event::default().event("state").data(state_json));
    let initial = tokio_stream::once(state_event);

    Sse::new(FuturesStreamExt::boxed(FuturesStreamExt::chain(initial, live)))
}

async fn persist_user_message(
    state: &AppState,
    thread: &ThreadRow,
    input: &SendInput,
) -> anyhow::Result<MessageRow> {
    let user_parts = serde_json::to_string(&[MessagePart::text(input.prompt.as_str())])
        .unwrap_or_else(|_| "[]".into());
    state
        .db
        .add_message(NewMessage {
            thread_id: thread.id.clone(),
            role: "user".into(),
            content: input.prompt.clone(),
            thinking: None,
            parts: user_parts,
            attachments: serde_json::to_string(&input.att_meta).unwrap_or_else(|_| "[]".into()),
        })
        .await
}

async fn run_thread(
    state: AppState,
    run: Arc<RunState>,
    user: crate::db::UserRow,
    thread: ThreadRow,
    input: SendInput,
    user_msg: MessageRow,
) -> anyhow::Result<()> {
    run.emit(
        "user_message",
        &serde_json::to_string(&MessageOut::from(user_msg)).unwrap_or_else(|_| "{}".into()),
    );

    let part_callback: PartCallback = Arc::new({
        let run = run.clone();
        move |ev: PartEvent| {
            let part = ev.part().clone();
            let is_tool_update = ev.is_update() && part.tool_id().is_some();
            run.apply_part(part, is_tool_update);
            let event = if is_tool_update { "part_update" } else { "part" };
            if let Ok(json) = serde_json::to_string(ev.part()) {
                run.emit(event, &json);
            }
        }
    });
    let permission_callback =
        build_permission_callback(state.clone(), user.id, thread.id.clone(), run.clone());
    let ask_callback =
        build_ask_callback(state.clone(), user.id, thread.id.clone(), run.clone());

    let provider_result = call_provider(
        &state,
        &user,
        &thread,
        &input,
        Some(permission_callback),
        Some(ask_callback),
        Some(part_callback),
    )
    .await;

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let (new_session_id, new_title, parts) = match provider_result {
        Ok(t) => t,
        Err(e) => {
            let _ = state
                .db
                .add_message(NewMessage {
                    thread_id: thread.id.clone(),
                    role: "error".into(),
                    content: format!("provider error: {e}"),
                    thinking: None,
                    parts: "[]".into(),
                    attachments: "[]".into(),
                })
                .await;
            let _ = state.db.touch_thread(&thread.id).await;
            return Err(e);
        }
    };

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let assistant_msg = persist_assistant_reply(
        &state,
        &thread.id,
        user.id,
        &parts,
        new_session_id,
        new_title,
        &run,
    )
    .await
    .map_err(|_| anyhow::anyhow!("failed to save assistant message"))?;

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let _ = run.set_status(RunStatus::Completed).await;
    run.emit(
        "done",
        &serde_json::to_string(&MessageOut::from(assistant_msg)).unwrap_or_else(|_| "{}".into()),
    );

    Ok(())
}

#[derive(Clone)]
struct SendInput {
    prompt: String,
    mode: String,
    attachments: Vec<Attachment>,
    att_meta: Vec<serde_json::Value>,
}

fn normalize_mode(raw: &str) -> String {
    let trimmed = raw.trim().to_lowercase();
    match trimmed.as_str() {
        "plan" => "plan".to_string(),
        "ask" => "ask".to_string(),
        _ => "code".to_string(),
    }
}

async fn parse_send_multipart(mut multipart: Multipart) -> Result<SendInput, Response> {
    let mut prompt: Option<String> = None;
    let mut mode: String = "code".to_string();
    let mut attachments: Vec<Attachment> = Vec::new();
    let mut att_meta: Vec<serde_json::Value> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let mime = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
        };
        if name == "prompt" {
            prompt = Some(String::from_utf8_lossy(&bytes).to_string());
        } else if name == "mode" {
            let raw = String::from_utf8_lossy(&bytes).to_string();
            mode = normalize_mode(&raw);
        } else if !filename.is_empty() {
            if bytes.len() > 8 * 1024 * 1024 {
                return Err((
                    StatusCode::PAYLOAD_TOO_LARGE,
                    Json(crate::api::ApiError::new(
                        "attachment too large (max 8 MiB)",
                    )),
                )
                    .into_response());
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
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("prompt is required")),
            )
                .into_response())
        }
    };
    if prompt.len() > 64 * 1024 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("prompt too long (max 64 KiB)")),
        )
            .into_response());
    }
    Ok(SendInput {
        prompt,
        mode,
        attachments,
        att_meta,
    })
}

async fn call_provider(
    state: &AppState,
    user: &crate::db::UserRow,
    thread: &ThreadRow,
    input: &SendInput,
    permission_callback: Option<PermissionCallback>,
    ask_callback: Option<AskCallback>,
    part_callback: Option<PartCallback>,
) -> anyhow::Result<(Option<String>, Option<String>, Vec<MessagePart>)> {
    let provider = state.provider_for_user(user);
    let working_dir = project_working_dir_for_thread(state, thread).await?;

    let options = SendOptions {
        model: thread.model.clone(),
        working_dir,
        permission_mode: thread.permission_mode.clone(),
        permissions: thread.permissions.clone(),
        attachments: input.attachments.clone(),
        permission_callback,
        ask_callback,
        part_callback,
        interaction_mode: input.mode.clone(),
    };

    if let Some(sid) = thread.devin_session_id.as_ref() {
        provider
            .send(crate::providers::SendRequest {
                session_id: sid.clone(),
                prompt: input.prompt.clone(),
                options,
            })
            .await
            .map(|r| (None, None, r.parts))
    } else {
        provider
            .start(StartRequest {
                prompt: input.prompt.clone(),
                options,
            })
            .await
            .map(|r| (Some(r.session_id), Some(r.title), r.parts))
    }
}

fn build_permission_callback(
    state: AppState,
    user_id: i64,
    thread_id: String,
    run: Arc<RunState>,
) -> PermissionCallback {
    Arc::new(
        move |req: PermissionRequest| -> Pin<Box<dyn Future<Output = PermissionOutcome> + Send>> {
            let state = state.clone();
            let run = run.clone();
            let thread_id = thread_id.clone();
            Box::pin(async move {
                let (response_tx, response_rx) = tokio::sync::oneshot::channel::<String>();
                let _cleanup = RemoveOnDrop::new(state.clone(), run.clone(), req.request_id.clone());

                {
                    let mut map = state.pending_permission_requests.lock().await;
                    map.insert(
                        req.request_id.clone(),
                        PendingPermissionRequest {
                            user_id,
                            thread_id,
                            sender: response_tx,
                        },
                    );
                }

                run.set_permission_request(Some(req.clone()));
                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        run.set_permission_request(None);
                        return PermissionOutcome::Cancel;
                    }
                };
                run.emit("permission_request", &payload);

                // Long timeout so users can disconnect, reload, and still
                // respond to permission requests for multi-day runs.
                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.set_permission_request(None);

                match result {
                    Ok(Ok(option_id)) if !option_id.is_empty() => {
                        PermissionOutcome::Allow { option_id }
                    }
                    _ => PermissionOutcome::Cancel,
                }
            })
        },
    ) as PermissionCallback
}

/// Removes a pending permission request from the map and the run snapshot
/// when the callback future is dropped (e.g. cancelled or the connection
/// closes), preventing memory leaks and abandoned senders.
struct RemoveOnDrop {
    state: Option<AppState>,
    run: Option<Arc<RunState>>,
    request_id: String,
}

impl RemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, request_id: String) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            request_id,
        }
    }
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            let request_id = self.request_id.clone();
            tokio::spawn(async move {
                let _ = state
                    .pending_permission_requests
                    .lock()
                    .await
                    .remove(&request_id);
            });
        }
        if let Some(run) = self.run.take() {
            if let Ok(guard) = run.permission_request.lock() {
                if guard
                    .as_ref()
                    .is_some_and(|r| r.request_id == self.request_id)
                {
                    drop(guard);
                    run.set_permission_request(None);
                }
            }
        }
    }
}

#[derive(Debug, Deserialize)]
struct PermissionResponseBody {
    option_id: Option<String>,
}

async fn respond_permission(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, request_id)): Path<(String, String)>,
    Json(body): Json<PermissionResponseBody>,
) -> impl IntoResponse {
    // Verify the user still owns the thread before accepting a response.
    if !matches!(state.db.get_thread(&thread_id, user.id).await, Ok(Some(_))) {
        return StatusCode::NOT_FOUND;
    }

    let sender = {
        let mut map = state.pending_permission_requests.lock().await;
        map.remove(&request_id)
    };

    match sender {
        Some(pending) if pending.user_id == user.id && pending.thread_id == thread_id => {
            if let Some(option_id) = body.option_id {
                match pending.sender.send(option_id) {
                    Ok(()) => StatusCode::OK,
                    Err(_) => StatusCode::GONE,
                }
            } else {
                // Drop the sender without responding, which signals cancellation
                // to the waiting provider.
                StatusCode::OK
            }
        }
        _ => StatusCode::NOT_FOUND,
    }
}

fn build_ask_callback(
    state: AppState,
    user_id: i64,
    thread_id: String,
    run: Arc<RunState>,
) -> AskCallback {
    Arc::new(
        move |req: AskRequest| -> Pin<Box<dyn Future<Output = AskOutcome> + Send>> {
            let state = state.clone();
            let run = run.clone();
            let thread_id = thread_id.clone();
            Box::pin(async move {
                let (response_tx, response_rx) =
                    tokio::sync::oneshot::channel::<Option<HashMap<String, serde_json::Value>>>();
                let _cleanup =
                    AskRemoveOnDrop::new(state.clone(), run.clone(), req.request_id.clone());

                {
                    let mut map = state.pending_ask_requests.lock().await;
                    map.insert(
                        req.request_id.clone(),
                        PendingAskRequest {
                            user_id,
                            thread_id,
                            sender: response_tx,
                        },
                    );
                }

                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        return AskOutcome::Cancel;
                    }
                };
                run.set_ask_request(Some(req));
                run.emit("ask_request", &payload);

                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.set_ask_request(None);

                match result {
                    Ok(Ok(Some(answers))) => AskOutcome::Answers(answers),
                    _ => AskOutcome::Cancel,
                }
            })
        },
    ) as AskCallback
}

struct AskRemoveOnDrop {
    state: Option<AppState>,
    run: Option<Arc<RunState>>,
    request_id: String,
}

impl AskRemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, request_id: String) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            request_id,
        }
    }
}

impl Drop for AskRemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            let request_id = self.request_id.clone();
            tokio::spawn(async move {
                let _ = state.pending_ask_requests.lock().await.remove(&request_id);
            });
        }
        if let Some(run) = self.run.take() {
            if let Ok(guard) = run.ask_request.lock() {
                if guard.as_ref().is_some_and(|r| r.request_id == self.request_id) {
                    drop(guard);
                    run.set_ask_request(None);
                }
            }
        }
    }
}

#[derive(Debug, Deserialize)]
struct AskResponseBody {
    answers: Option<HashMap<String, serde_json::Value>>,
}

async fn respond_ask(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, request_id)): Path<(String, String)>,
    Json(body): Json<AskResponseBody>,
) -> impl IntoResponse {
    if !matches!(state.db.get_thread(&thread_id, user.id).await, Ok(Some(_))) {
        return StatusCode::NOT_FOUND;
    }

    let sender = {
        let mut map = state.pending_ask_requests.lock().await;
        map.remove(&request_id)
    };

    match sender {
        Some(pending) if pending.user_id == user.id && pending.thread_id == thread_id => {
            match pending.sender.send(body.answers) {
                Ok(()) => StatusCode::OK,
                Err(_) => StatusCode::GONE,
            }
        }
        _ => StatusCode::NOT_FOUND,
    }
}

async fn persist_assistant_reply(
    state: &AppState,
    thread_id: &str,
    user_id: i64,
    parts: &[MessagePart],
    new_session_id: Option<String>,
    new_title: Option<String>,
    run: &RunState,
) -> Result<MessageRow, Response> {
    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(crate::api::map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

    let session_id_for_audit = new_session_id.clone();
    if let Some(sid) = new_session_id {
        if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(crate::api::map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
        }
        let _ = state
            .db
            .update_thread_session(thread_id, &sid, new_title.as_deref())
            .await;
    }

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(crate::api::map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }
    let _ = state.db.touch_thread(thread_id).await;

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(crate::api::map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

    let reply = collect_text(parts);
    let thinking = collect_thinking(parts);
    let thinking = (!thinking.is_empty()).then_some(thinking);
    let parts_json = serde_json::to_string(parts).unwrap_or_else(|_| "[]".into());
    let assistant_msg = state
        .db
        .add_message(NewMessage {
            thread_id: thread_id.into(),
            role: "assistant".into(),
            content: reply,
            thinking,
            parts: parts_json,
            attachments: "[]".into(),
        })
        .await
        .map_err(|e| crate::api::map_err_internal(e).into_response())?;

    if run.cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        let _ = state.db.delete_message(assistant_msg.id).await;
        return Err(crate::api::map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

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
/// Otherwise fall back to the user's home directory.
async fn project_working_dir_for_thread(
    state: &AppState,
    thread: &ThreadRow,
) -> anyhow::Result<PathBuf> {
    if let Some(pid) = thread.project_id {
        if let Ok(Some(p)) = state.db.get_project(pid, thread.user_id).await {
            let project_path = tokio::fs::canonicalize(&p.path)
                .await
                .unwrap_or_else(|_| PathBuf::from(&p.path));
            if let Some(wt) = &thread.worktree_path {
                let path = PathBuf::from(wt);
                if path.is_absolute() {
                    match tokio::fs::canonicalize(&path).await {
                        Ok(canonical) if canonical.starts_with(&project_path) => {
                            return Ok(canonical)
                        }
                        _ => {}
                    }
                }
            }
            return Ok(project_path);
        }
    }
    Ok(state.config.home_dir.clone())
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
                _ => (
                    StatusCode::NOT_FOUND,
                    Json(crate::api::ApiError::new("project not found")),
                )
                    .into_response(),
            },
            None => (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("thread has no project")),
            )
                .into_response(),
        },
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
