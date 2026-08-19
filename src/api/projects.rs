//! Project API routes.

use std::path::PathBuf;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewProject, ProjectRow};
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/projects", get(list).post(create))
        .route("/api/projects/reorder", patch(reorder))
        .route("/api/projects/:id", delete(delete_one).patch(rename))
        .route("/api/projects/:id/threads", get(list_threads))
}

#[derive(Debug, Serialize)]
pub struct ProjectOut {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub position: i64,
    pub is_repo: bool,
    pub branch: String,
    pub created_at: String,
    pub updated_at: String,
}

impl ProjectOut {
    pub async fn from_row(state: &AppState, p: ProjectRow) -> Self {
        let (is_repo, branch) = match state.git.repo_status(std::path::Path::new(&p.path)).await {
            Ok(s) => (s.is_repo, s.branch),
            Err(_) => (false, String::new()),
        };
        Self {
            id: p.id,
            name: p.name,
            path: p.path,
            position: p.position,
            is_repo,
            branch,
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
            let mut out = Vec::with_capacity(rows.len());
            for p in rows {
                out.push(ProjectOut::from_row(&state, p).await);
            }
            Json(out).into_response()
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
    // An empty path is interpreted as the user's home directory so the
    // project picker can select the home root.

    // Validate the path is within the configured file root.
    let abs = match resolve_and_ensure_dir(&state, path).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error = %e, path = %path, "project path resolution failed");
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project path")),
            )
                .into_response();
        }
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

    if state
        .db
        .get_project_by_path(user.id, &path_str)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return (
            StatusCode::CONFLICT,
            Json(crate::api::ApiError::new("project path already exists")),
        )
            .into_response();
    }

    if state
        .db
        .get_project_by_name(user.id, name)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return (
            StatusCode::CONFLICT,
            Json(crate::api::ApiError::new("project name already exists")),
        )
            .into_response();
    }

    let position = match state.db.next_project_position(user.id).await {
        Ok(p) => p,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let new = NewProject {
        user_id: user.id,
        name: name.to_string(),
        path: path_str,
        position,
    };

    match state.db.create_project(new).await {
        Ok(p) => {
            let out = ProjectOut::from_row(&state, p).await;
            (StatusCode::CREATED, Json(out)).into_response()
        }
        Err(e) => {
            // A duplicate name or path can race the pre-checks above.
            if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
                if db_err.is_unique_violation() {
                    return (
                        StatusCode::CONFLICT,
                        Json(crate::api::ApiError::new(
                            "project with this name or path already exists",
                        )),
                    )
                        .into_response();
                }
            }
            crate::api::map_err_internal(e).into_response()
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct ReorderProjects {
    pub project_ids: Vec<i64>,
}

#[derive(Debug, Deserialize)]
pub struct RenameProject {
    pub name: String,
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<RenameProject>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project name is required")),
        )
            .into_response();
    }

    // Verify ownership and fetch the current row.
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    if name == project.name {
        let out = ProjectOut::from_row(&state, project).await;
        return Json(out).into_response();
    }

    // Prevent duplicate names for the same user.
    if state
        .db
        .get_project_by_name(user.id, name)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return (
            StatusCode::CONFLICT,
            Json(crate::api::ApiError::new("project name already exists")),
        )
            .into_response();
    }

    if let Err(e) = state.db.rename_project(id, user.id, name).await {
        if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
            if db_err.is_unique_violation() {
                return (
                    StatusCode::CONFLICT,
                    Json(crate::api::ApiError::new(
                        "project with this name already exists",
                    )),
                )
                    .into_response();
            }
        }
        return crate::api::map_err_internal(e).into_response();
    }

    match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => Json(ProjectOut::from_row(&state, p).await).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn reorder(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<ReorderProjects>,
) -> Response {
    if req.project_ids.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project_ids is required")),
        )
            .into_response();
    }

    match state.db.update_project_positions(user.id, &req.project_ids).await {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => {
            tracing::warn!(error = %e, user_id = user.id, "project reorder failed");
            (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(e.to_string())),
            )
                .into_response()
        }
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
        Ok(rows) => {
            Json(rows
                .into_iter()
                .map(crate::api::threads::ThreadOut::from)
                .collect::<Vec<_>>())
            .into_response()
        }
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

    // Treat `.` and empty paths as the home directory so the user can add the
    // home root from the folder picker.
    if path.is_empty() || path == "." {
        let resolved = state.config.home_dir.clone();
        tokio::fs::create_dir_all(&resolved).await?;
        return Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved));
    }

    // Reject `..` in any path component to prevent traversal through symlinks.
    if path.split(['/', '\\']).any(|c| c == "..") {
        return Err(anyhow::anyhow!("path traversal is not allowed"));
    }

    // Resolve relative to home. Unlike the file manager, project creation allows
    // absolute paths, so a symlink inside the home directory that points outside
    // is also accepted.
    let candidate = state.config.home_dir.join(&path);
    let resolved = paths::resolve(&candidate, Some(&state.config.home_dir), None)
        .ok_or_else(|| anyhow::anyhow!("invalid project path"))?;

    // Ensure the directory exists.
    tokio::fs::create_dir_all(&resolved).await?;

    // Canonicalize so the stored path is stable.
    Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved))
}

fn normalize_path(path: &str, home: &std::path::Path) -> String {
    let mut s = path.trim().to_string();

    // Strip matching surrounding quotes, e.g. "/path/with spaces" or '/path'.
    if let Some(inner) = s.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        s = inner.to_string();
    } else if let Some(inner) = s.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')) {
        s = inner.to_string();
    }

    // Expand a leading `~` to the home directory.
    if s == "~" || s == "~/" || s == "~\\" {
        s = home.to_string_lossy().to_string();
    } else if s.starts_with("~/") || s.starts_with("~\\") {
        let sep = if s.starts_with("~/") { '/' } else { '\\' };
        let rest = s[2..].trim_start_matches(sep);
        s = if rest.is_empty() {
            home.to_string_lossy().to_string()
        } else {
            home.join(rest).to_string_lossy().to_string()
        };
    }

    s
}
