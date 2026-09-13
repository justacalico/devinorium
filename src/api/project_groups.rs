//! Project group API routes.
//!
//! Project groups organize the sidebar project list. Each project belongs to
//! at most one group; deleting a group ungroups its projects instead of
//! deleting them.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewProjectGroup, ProjectGroupRow};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/project-groups", get(list).post(create))
        .route(
            "/api/project-groups/:id",
            get(get_one).patch(rename).delete(delete_one),
        )
}

#[derive(Debug, Serialize)]
pub struct ProjectGroupOut {
    pub id: i64,
    pub name: String,
    pub position: i64,
    pub created_at: String,
}

impl From<ProjectGroupRow> for ProjectGroupOut {
    fn from(g: ProjectGroupRow) -> Self {
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
    Query(pagination): Query<crate::api::pagination::Pagination>,
) -> Response {
    let (limit, offset) = pagination.bounds();
    match state.db.list_project_groups(user.id, limit, offset).await {
        Ok(rows) => Json(
            rows.into_iter()
                .map(ProjectGroupOut::from)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateProjectGroup {
    pub name: String,
    /// Projects to move into the new group right away.
    pub project_ids: Option<Vec<i64>>,
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateProjectGroup>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() || name.len() > 100 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("name must be 1-100 chars")),
        )
            .into_response();
    }

    let mut project_ids = req.project_ids.unwrap_or_default();
    project_ids.sort_unstable();
    project_ids.dedup();
    if !project_ids.is_empty() {
        match state.db.owned_project_ids(user.id, &project_ids).await {
            Ok(owned) if owned.len() == project_ids.len() => {}
            Ok(_) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("unknown project")),
                )
                    .into_response()
            }
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        }
    }

    if state
        .db
        .get_project_group_by_name(user.id, name)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return (
            StatusCode::CONFLICT,
            Json(crate::api::ApiError::new("group name already exists")),
        )
            .into_response();
    }

    let position = match state.db.next_project_group_position(user.id).await {
        Ok(p) => p,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let new = NewProjectGroup {
        user_id: user.id,
        name: name.to_string(),
        position,
    };
    let group = match state.db.create_project_group(new).await {
        Ok(g) => g,
        Err(e) => {
            if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
                if db_err.is_unique_violation() {
                    return (
                        StatusCode::CONFLICT,
                        Json(crate::api::ApiError::new("group name already exists")),
                    )
                        .into_response();
                }
            }
            return crate::api::map_err_internal(e).into_response();
        }
    };

    for pid in &project_ids {
        if let Err(e) = state
            .db
            .set_project_group(*pid, user.id, Some(group.id))
            .await
        {
            return crate::api::map_err_internal(e).into_response();
        }
    }
    (StatusCode::CREATED, Json(ProjectGroupOut::from(group))).into_response()
}

async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.get_project_group(id, user.id).await {
        Ok(Some(g)) => Json(ProjectGroupOut::from(g)).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct RenameProjectGroup {
    pub name: String,
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<RenameProjectGroup>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() || name.len() > 100 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("name must be 1-100 chars")),
        )
            .into_response();
    }

    match state.db.get_project_group(id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    if let Some(existing) = state
        .db
        .get_project_group_by_name(user.id, name)
        .await
        .ok()
        .flatten()
    {
        if existing.id != id {
            return (
                StatusCode::CONFLICT,
                Json(crate::api::ApiError::new("group name already exists")),
            )
                .into_response();
        }
    }

    match state.db.rename_project_group(id, user.id, name).await {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => {
            if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
                if db_err.is_unique_violation() {
                    return (
                        StatusCode::CONFLICT,
                        Json(crate::api::ApiError::new("group name already exists")),
                    )
                        .into_response();
                }
            }
            crate::api::map_err_internal(e).into_response()
        }
    }
}

async fn delete_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.delete_project_group(id, user.id).await {
        Ok(0) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
