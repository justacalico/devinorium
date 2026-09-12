//! Instance settings routes.
//!
//! The clone root and worktree root are owner-only settings stored on the
//! owner user row. Non-owner users can read them so they know where clones
//! and worktrees will land.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put, Router};
use axum::Json;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/settings/clone-root", get(get_clone_root))
        .route("/api/settings/clone-root", put(set_clone_root))
        .route("/api/settings/worktree-root", get(get_worktree_root))
        .route("/api/settings/worktree-root", put(set_worktree_root))
}

#[derive(Debug, Serialize)]
struct CloneRootResponse {
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SetCloneRootRequest {
    path: Option<String>,
}

#[derive(Debug, Serialize)]
struct WorktreeRootResponse {
    path: String,
}

#[derive(Debug, Deserialize)]
struct SetWorktreeRootRequest {
    path: Option<String>,
}

/// Validate a user-supplied directory path for a path setting: expand `~`,
/// require an absolute path without traversal, resolve symlinks, and create
/// the directory when missing. Returns the canonical path to store.
async fn checked_dir_path(state: &AppState, path: &str) -> Result<String, Response> {
    // Expand `~` to the home directory while still validating the final string.
    let path = paths::normalize_path(path, &state.config.home_dir);
    let p = Path::new(&path);
    if !p.is_absolute() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("path must be absolute")),
        )
            .into_response());
    }

    // Reject `..` and other traversal components.
    for c in p.components() {
        if matches!(c, std::path::Component::ParentDir) {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("path traversal is not allowed")),
            )
                .into_response());
        }
    }

    // Resolve to a canonical absolute path. This rejects non-existent tails
    // that try to escape via `..` and follows symlinks, so the stored path is
    // stable.
    let resolved = match paths::resolve(p, None, None) {
        Some(r) => r,
        None => {
            return Err(
                (StatusCode::BAD_REQUEST, Json(ApiError::new("invalid path"))).into_response(),
            );
        }
    };

    // Create the directory if missing; reject if it exists as a file.
    match tokio::fs::try_exists(&resolved).await {
        Ok(true) => match tokio::fs::metadata(&resolved).await {
            Ok(meta) if !meta.is_dir() => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new("path is not a directory")),
                )
                    .into_response());
            }
            Ok(_) => {}
            Err(e) => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot access path: {e}"))),
                )
                    .into_response());
            }
        },
        Ok(false) => {
            if let Err(e) = tokio::fs::create_dir_all(&resolved).await {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot create directory: {e}"))),
                )
                    .into_response());
            }
        }
        Err(e) => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError::new(format!("cannot check path: {e}"))),
            )
                .into_response());
        }
    }

    let final_path = match tokio::fs::canonicalize(&resolved).await {
        Ok(c) => c,
        Err(_) => resolved,
    };
    Ok(final_path.to_string_lossy().to_string())
}

/// The directory managed worktree roots live under for `user_id`: the
/// owner-configured setting resolved to a canonical absolute path, with `~`
/// (the default) expanding to the server home directory.
pub(crate) async fn worktree_root(state: &AppState, user_id: i64) -> anyhow::Result<PathBuf> {
    let configured = state.db.get_worktree_root(user_id).await?;
    let normalized = paths::normalize_path(&configured, &state.config.home_dir);
    paths::resolve(Path::new(&normalized), None, None)
        .ok_or_else(|| anyhow::anyhow!("invalid worktree root"))
}

async fn get_clone_root(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.get_clone_root(user.id).await {
        Ok(path) => Json(CloneRootResponse { path }).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn set_clone_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetCloneRootRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    let path = req.path.as_deref().map(|s| s.trim());
    let path = match path {
        None | Some("") => {
            if let Err(e) = state.db.set_clone_root(user.id, None).await {
                return map_err_internal(e).into_response();
            }
            return Json(CloneRootResponse { path: None }).into_response();
        }
        Some(p) => p,
    };

    let path = match checked_dir_path(&state, path).await {
        Ok(p) => p,
        Err(resp) => return resp,
    };

    if let Err(e) = state.db.set_clone_root(user.id, Some(&path)).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "clone_root.set",
            &serde_json::json!({"path": &path}),
            None,
        )
        .await;

    Json(CloneRootResponse {
        path: Some(path.clone()),
    })
    .into_response()
}

async fn get_worktree_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    match state.db.get_worktree_root(user.id).await {
        // The stored `~` default is returned expanded so the settings page
        // shows the real directory.
        Ok(path) => Json(WorktreeRootResponse {
            path: paths::normalize_path(&path, &state.config.home_dir),
        })
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn set_worktree_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetWorktreeRootRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    // An empty value restores the home-directory default. A bare `~` is
    // stored verbatim so the value keeps tracking the server home directory
    // if it ever changes.
    let raw = req.path.as_deref().map(|s| s.trim());
    let stored = match raw {
        None | Some("") | Some("~") | Some("~/") | Some("~\\") => "~".to_string(),
        Some(p) => match checked_dir_path(&state, p).await {
            Ok(p) => p,
            Err(resp) => return resp,
        },
    };

    if let Err(e) = state.db.set_worktree_root(user.id, &stored).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "worktree_root.set",
            &serde_json::json!({"path": &stored}),
            None,
        )
        .await;

    Json(WorktreeRootResponse {
        path: paths::normalize_path(&stored, &state.config.home_dir),
    })
    .into_response()
}
