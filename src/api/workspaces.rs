//! Workspace API routes.
//!
//! Workspaces are directories constrained to the configured
//! `DEVINORIUM_WORKSPACE_ROOTS`. The file manager and Devin sessions operate
//! within a workspace.

use std::path::PathBuf;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewWorkspace, WorkspaceRow};
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/workspaces", get(list).post(create))
        .route("/api/workspaces/:id", get(get_one).delete(delete))
}

#[derive(Debug, Serialize)]
pub struct WorkspaceOut {
    pub id: i64,
    pub path: String,
    pub label: String,
    pub created_at: String,
    pub last_used_at: String,
}

impl From<WorkspaceRow> for WorkspaceOut {
    fn from(w: WorkspaceRow) -> Self {
        Self {
            id: w.id,
            path: w.path,
            label: w.label,
            created_at: w.created_at,
            last_used_at: w.last_used_at,
        }
    }
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.list_workspaces(user.id).await {
        Ok(rows) => Json(rows.into_iter().map(WorkspaceOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateWorkspace {
    pub path: String,
    pub label: String,
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateWorkspace>,
) -> Response {
    if req.label.trim().is_empty() || req.label.len() > 128 {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("label must be 1-128 chars")),
        )
            .into_response();
    }
    let path = PathBuf::from(&req.path);
    let roots = &state.config.workspace_roots;
    // For relative paths, try resolving against each root as a base.
    let resolved = if path.is_absolute() {
        paths::resolve_within(&path, None, roots)
    } else {
        roots.iter().find_map(|root| paths::resolve_within(&path, Some(root), roots))
    };
    let resolved = match resolved {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(
                    "path is not within any configured workspace root",
                )),
            )
                .into_response();
        }
    };
    // Ensure the directory exists (create it).
    if let Err(e) = tokio::fs::create_dir_all(&resolved).await {
        if e.kind() != std::io::ErrorKind::AlreadyExists {
            return crate::api::map_err_internal(e).into_response();
        }
    }
    match state
        .db
        .create_workspace(NewWorkspace {
            user_id: user.id,
            path: resolved.to_string_lossy().to_string(),
            label: req.label,
        })
        .await
    {
        Ok(w) => (StatusCode::CREATED, Json(WorkspaceOut::from(w))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn get_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.get_workspace(id, user.id).await {
        Ok(Some(w)) => Json(WorkspaceOut::from(w)).into_response(),
        Ok(None) => (StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("not found"))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    // Only removes the workspace record, never the directory contents.
    match state.db.delete_workspace(id, user.id).await {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
