//! Thread group API routes.
//!
//! Thread groups are lightweight visual containers for organizing threads in
//! the sidebar. They are created by dragging one thread onto another, or
//! explicitly via the API. Deleting a group ungroups its threads (sets
//! thread_group_id to NULL).

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewThreadGroup, ThreadGroupRow};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/thread-groups", get(list).post(create))
        .route("/api/thread-groups/:id", get(get_one).patch(rename).delete(delete))
}

#[derive(Debug, Serialize)]
pub struct ThreadGroupOut {
    pub id: i64,
    pub name: String,
    pub position: i64,
    pub created_at: String,
}

impl From<ThreadGroupRow> for ThreadGroupOut {
    fn from(g: ThreadGroupRow) -> Self {
        Self {
            id: g.id,
            name: g.name,
            position: g.position,
            created_at: g.created_at,
        }
    }
}

async fn list(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    match state.db.list_thread_groups(user.id).await {
        Ok(rows) => Json(rows.into_iter().map(ThreadGroupOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateGroup {
    pub name: Option<String>,
    pub thread_ids: Option<Vec<String>>,
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateGroup>,
) -> Response {
    let name = req.name.unwrap_or_else(|| "New Group".into());
    if name.trim().is_empty() || name.len() > 100 {
        return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("name must be 1-100 chars"))).into_response();
    }
    let position = match state.db.next_group_position(user.id).await {
        Ok(p) => p,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let new = NewThreadGroup {
        user_id: user.id,
        name: name.trim().to_string(),
        position,
    };
    let group = match state.db.create_thread_group(new).await {
        Ok(g) => g,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    // Optionally move threads into the new group.
    if let Some(thread_ids) = req.thread_ids {
        for tid in &thread_ids {
            let _ = state.db.move_thread_to_group(tid, user.id, Some(group.id)).await;
        }
    }
    (StatusCode::CREATED, Json(ThreadGroupOut::from(group))).into_response()
}

async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.get_thread_group(id, user.id).await {
        Ok(Some(g)) => Json(ThreadGroupOut::from(g)).into_response(),
        Ok(None) => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct RenameGroup {
    pub name: String,
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<RenameGroup>,
) -> Response {
    if req.name.trim().is_empty() || req.name.len() > 100 {
        return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("name must be 1-100 chars"))).into_response();
    }
    match state.db.rename_thread_group(id, user.id, &req.name).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.delete_thread_group(id, user.id).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
