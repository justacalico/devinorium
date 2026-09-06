//! Thread CRUD and message listing routes.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use uuid::Uuid;

use crate::api::map_err_internal;
use crate::api::pagination::Pagination;
use crate::auth::session::CurrentUser;
use crate::db::NewThread;
use crate::AppState;

use super::persistence::active_run_plan;
use super::{
    CreateThread, GetThread, ListMessages, MessageOut, PinThread, ThreadOut, UpdateThread,
};
use crate::db::messages::TURN_LIMIT_DEFAULT;

pub(super) async fn list(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(pagination): Query<Pagination>,
) -> Response {
    let (limit, offset) = pagination.bounds();
    match state.db.list_threads(user.id, limit, offset).await {
        Ok(rows) => Json(rows.into_iter().map(ThreadOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn create(
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

    // Remove empty threads for this user+project before creating a new one.
    let _ = state.db.delete_empty_threads(user.id, req.project_id).await;

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
    // The thread's provider defaults to the user's configured provider.
    let provider_id = req
        .provider
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&user.provider_id);
    if crate::providers::provider_name(provider_id).is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("unknown provider")),
        )
            .into_response();
    }
    let provider_id = provider_id.to_string();

    let permission_mode = req.permission_mode.unwrap_or_else(|| "normal".into());
    if !is_valid_permission_mode(&permission_mode) {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid permission_mode")),
        )
            .into_response();
    }
    // The configured default model belongs to the user's default provider;
    // threads on another provider leave it empty so the provider picks from
    // its own catalog when the first message is sent.
    let model = req
        .model
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .unwrap_or_else(|| {
            if provider_id == user.provider_id {
                state.config.default_model.clone()
            } else {
                String::new()
            }
        });
    if model.len() > 100 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("model must be 1-100 chars")),
        )
            .into_response();
    }
    let title = req.title.unwrap_or_else(|| "New thread".into());
    let title_user_set = title != "New thread";
    let new = NewThread {
        id: Uuid::new_v4().to_string(),
        user_id: user.id,
        project_id: req.project_id,
        thread_group_id: req.thread_group_id,
        title,
        title_user_set,
        provider_id,
        model,
        permission_mode,
        permissions: req.permissions,
        branch: req.branch,
        worktree_path: req.worktree_path,
    };
    match state.db.create_thread(new).await {
        Ok(t) => (StatusCode::CREATED, Json(ThreadOut::from(t))).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Query(query): Query<GetThread>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => {
            let total = state.db.count_messages(&id).await.unwrap_or(0);
            let mut messages = Vec::new();
            let mut page_meta = None;
            if query.include_messages.as_deref().is_some_and(truthy) {
                if query.turn_limit.is_some() || query.before_cursor.is_some() {
                    let turn_limit = query.turn_limit.unwrap_or(TURN_LIMIT_DEFAULT).clamp(1, 200);
                    let before_cursor = query
                        .before_cursor
                        .as_deref()
                        .and_then(crate::db::messages::TurnCursor::decode);
                    match state
                        .db
                        .list_messages_turn_windowed(&id, before_cursor, turn_limit)
                        .await
                    {
                        Ok((rows, _total, before_cursor, has_more)) => {
                            let raw_count = rows.len();
                            messages = rows.into_iter().map(MessageOut::from).collect::<Vec<_>>();
                            page_meta = Some((before_cursor, has_more, turn_limit, raw_count));
                        }
                        Err(e) => return map_err_internal(e).into_response(),
                    }
                } else {
                    let limit = query.limit.unwrap_or(50).clamp(1, 200);
                    match state
                        .db
                        .list_messages_paginated(&id, None, None, limit)
                        .await
                    {
                        Ok(rows) => {
                            messages = rows.into_iter().map(MessageOut::from).collect::<Vec<_>>();
                        }
                        Err(e) => return map_err_internal(e).into_response(),
                    }
                }
            }
            let db_plan = match state.db.get_latest_plan(&id).await {
                Ok(Some(row)) => row.to_plan().ok(),
                _ => None,
            };
            let (has_active_run, active_plan) = active_run_plan(&state.thread_runner, &id).await;
            let plan = if has_active_run { active_plan } else { db_plan };
            let mut body = serde_json::json!({
                "thread": ThreadOut::from(t),
                "total_messages": total,
                "messages": messages,
                "plan": plan,
            });
            if let Some((before_cursor, has_more, turn_limit, raw_count)) = page_meta {
                let before_cursor = before_cursor.map(|c| c.encode());
                body["before_cursor"] = before_cursor.into();
                body["has_more"] = has_more.into();
                body["turn_limit"] = turn_limit.into();
                body["raw_count"] = raw_count.into();
            }
            Json(body).into_response()
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Json(req): Json<UpdateThread>,
) -> Response {
    // Verify ownership up front so every field update is gated on the
    // thread actually belonging to the caller.
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    // Validate all inputs before touching the database.
    if let Some(provider) = &req.provider {
        let provider = provider.trim();
        if crate::providers::provider_name(provider).is_none() {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("unknown provider")),
            )
                .into_response();
        }
        // A stored session id only means something to the provider that
        // created it, so the provider is locked once the conversation has
        // started. Start a new thread to switch providers.
        if provider != thread.provider_id && thread.devin_session_id.is_some() {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(
                    "provider cannot be changed once the conversation has started",
                )),
            )
                .into_response();
        }
    }
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
        if !is_valid_permission_mode(mode) {
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
            return map_err_internal(e).into_response();
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
    // A redundant provider write would trip the no-session guard needlessly.
    let provider_update = req
        .provider
        .as_deref()
        .map(str::trim)
        .filter(|p| *p != thread.provider_id);

    if provider_update.is_some()
        || req.model.is_some()
        || req.permission_mode.is_some()
        || req.permissions.is_some()
    {
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
                provider_update,
                model,
                req.permission_mode.as_deref(),
                permissions,
            )
            .await
        {
            return map_err_internal(e).into_response();
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
            return map_err_internal(e).into_response();
        }
    }

    Json(serde_json::json!({"ok": true})).into_response()
}

pub(super) async fn pin(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    Json(req): Json<PinThread>,
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
        Err(e) => return map_err_internal(e).into_response(),
    }

    if let Err(e) = state.db.set_thread_pinned(&id, user.id, req.pinned).await {
        return map_err_internal(e).into_response();
    }

    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => Json(ThreadOut::from(t)).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.delete_thread(&id, user.id).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn list_messages(
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

    let turn_based = query.turn_limit.is_some() || query.before_cursor.is_some();

    if !turn_based && query.before_id.is_some() && query.after_id.is_some() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new(
                "before_id and after_id cannot both be set",
            )),
        )
            .into_response();
    }

    if turn_based {
        let turn_limit = query.turn_limit.unwrap_or(TURN_LIMIT_DEFAULT).clamp(1, 200);
        let before_cursor = query
            .before_cursor
            .as_deref()
            .and_then(crate::db::messages::TurnCursor::decode);
        match state
            .db
            .list_messages_turn_windowed(&id, before_cursor, turn_limit)
            .await
        {
            Ok((rows, total, before_cursor, has_more)) => {
                let raw_count = rows.len();
                let before_cursor = before_cursor.map(|c| c.encode());
                return Json(serde_json::json!({
                    "messages": rows.into_iter().map(MessageOut::from).collect::<Vec<_>>(),
                    "total": total,
                    "turn_limit": turn_limit,
                    "raw_count": raw_count,
                    "before_cursor": before_cursor,
                    "has_more": has_more,
                }))
                .into_response();
            }
            Err(e) => return map_err_internal(e).into_response(),
        }
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
        Err(e) => map_err_internal(e).into_response(),
    }
}

fn truthy(value: &str) -> bool {
    matches!(value, "true" | "1" | "yes" | "on")
}

pub(super) async fn get_message(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, message_id)): Path<(String, i64)>,
    Query(query): Query<super::MessageChunkQuery>,
) -> Response {
    match state.db.get_thread(&thread_id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
    }

    let offset = query.offset.unwrap_or(0).max(0);
    let limit = query
        .limit
        .unwrap_or(crate::db::messages::MESSAGE_CHAR_BUDGET)
        .clamp(1, crate::db::messages::MESSAGE_CHAR_BUDGET);

    match state
        .db
        .get_message_chunk(&thread_id, message_id, offset, limit)
        .await
    {
        Ok(Some((row, total))) => Json(serde_json::json!({
            "message": MessageOut::from(row),
            "offset": offset,
            "limit": limit,
            "total_chars": total,
        }))
        .into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn get_message_full(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, message_id)): Path<(String, i64)>,
) -> Response {
    match state.db.get_thread(&thread_id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
    }

    match state.db.get_message_full(&thread_id, message_id).await {
        Ok(Some(row)) => {
            let mut out = MessageOut::from(row);
            out.truncated = false;
            out.total_chars = None;
            out.truncated_at = None;
            Json(serde_json::json!({"message": out})).into_response()
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

fn is_valid_permission_mode(mode: &str) -> bool {
    ["normal", "accept-edits", "smart", "bypass"].contains(&mode)
}

#[cfg(test)]
mod tests {
    use super::{is_valid_permission_mode, truthy};

    #[test]
    fn truthy_recognizes_common_boolean_strings() {
        assert!(truthy("true"));
        assert!(truthy("1"));
        assert!(truthy("yes"));
        assert!(truthy("on"));
        assert!(!truthy("false"));
        assert!(!truthy(""));
        assert!(!truthy("no"));
    }

    #[test]
    fn valid_permission_modes() {
        assert!(is_valid_permission_mode("normal"));
        assert!(is_valid_permission_mode("accept-edits"));
        assert!(is_valid_permission_mode("smart"));
        assert!(is_valid_permission_mode("bypass"));
        assert!(!is_valid_permission_mode("unknown"));
        assert!(!is_valid_permission_mode(""));
    }
}
