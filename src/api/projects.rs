//! Project API routes.

use std::path::PathBuf;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewProject, ProjectRow};
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/projects", get(list).post(create))
        .route("/api/projects/:id", delete(delete_one))
        .route("/api/projects/:id/threads", get(list_threads))
}

#[derive(Debug, Serialize)]
pub struct ProjectOut {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub created_at: String,
    pub updated_at: String,
}

impl From<ProjectRow> for ProjectOut {
    fn from(p: ProjectRow) -> Self {
        Self {
            id: p.id,
            name: p.name,
            path: p.path,
            created_at: p.created_at,
            updated_at: p.updated_at,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateProject {
    pub name: String,
    pub path: String,
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.list_projects(user.id).await {
        Ok(rows) => {
            Json(rows.into_iter().map(ProjectOut::from).collect::<Vec<_>>()).into_response()
        }
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateProject>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project name is required")),
        )
            .into_response();
    }

    let path = req.path.trim();
    if path.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project path is required")),
        )
            .into_response();
    }

    // Validate the path is within the configured file root.
    let Ok(abs) = resolve_and_ensure_dir(&state, path).await else {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid project path")),
        )
            .into_response();
    };

    let path_str = match abs.to_str() {
        Some(s) => s.to_string(),
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project path encoding")),
            )
                .into_response()
        }
    };

    let new = NewProject {
        user_id: user.id,
        name: name.to_string(),
        path: path_str,
    };

    match state.db.create_project(new).await {
        Ok(p) => (StatusCode::CREATED, Json(ProjectOut::from(p))).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn delete_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.delete_project(id, user.id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn list_threads(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    match state.db.list_threads_for_project(id, user.id).await {
        Ok(rows) => Json(
            rows.into_iter()
                .map(crate::api::threads::ThreadOut::from)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

/// Resolve the user-supplied path, create the directory if it doesn't exist,
/// and return the canonical absolute path. Paths are resolved relative to the
/// user's home directory unless they are absolute.
async fn resolve_and_ensure_dir(state: &AppState, path: &str) -> anyhow::Result<PathBuf> {
    let path = normalize_path(path, &state.config.home_dir);

    if std::path::Path::new(&path).is_absolute() {
        let resolved = paths::resolve(std::path::Path::new(&path), None, None)
            .ok_or_else(|| anyhow::anyhow!("invalid project path"))?;
        tokio::fs::create_dir_all(&resolved).await?;
        return Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved));
    }

    let candidate = state.config.home_dir.join(&path);
    let resolved = paths::resolve_within(&candidate, Some(&state.config.home_dir), &[state.config.home_dir.clone()])
        .ok_or_else(|| anyhow::anyhow!("invalid project path"))?;

    // Ensure the directory exists.
    tokio::fs::create_dir_all(&resolved).await?;

    // Canonicalize so the stored path is stable.
    Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved))
}

fn normalize_path(path: &str, home: &std::path::Path) -> String {
    let mut s = path.trim().to_string();

    // Strip matching surrounding quotes, e.g. "/path/with spaces" or '/path'.
    if s.len() >= 2 {
        let first = s.chars().next().unwrap();
        let last = s.chars().last().unwrap();
        if (first == last) && (first == '\"' || first == '\'') {
            s = s[1..s.len() - 1].to_string();
        }
    }

    // Expand a leading `~` to the home directory.
    if s == "~" || s.starts_with("~/") {
        s = home.join(&s[1..]).to_string_lossy().to_string();
    }

    s
}
