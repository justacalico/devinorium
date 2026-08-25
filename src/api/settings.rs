//! Instance settings routes.
//!
//! The clone root is an owner-only setting stored on the owner user row.
//! Non-owner users can read it so they know where clones will land.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put, Router};
use axum::Json;
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/settings/clone-root", get(get_clone_root))
        .route("/api/settings/clone-root", put(set_clone_root))
}

#[derive(Debug, Serialize)]
struct CloneRootResponse {
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SetCloneRootRequest {
    path: Option<String>,
}

async fn get_clone_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
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

    // Expand `~` to the home directory while still validating the final string.
    let path = paths::normalize_path(path, &state.config.home_dir);
    let p = Path::new(&path);
    if !p.is_absolute() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("path must be absolute")),
        )
            .into_response();
    }

    // Reject `..` and other traversal components.
    for c in p.components() {
        if matches!(c, std::path::Component::ParentDir) {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("path traversal is not allowed")),
            )
                .into_response();
        }
    }

    // Resolve to a canonical absolute path. This rejects non-existent tails
    // that try to escape via `..` and follows symlinks, so the stored path is
    // stable.
    let resolved = match paths::resolve(p, None, None) {
        Some(r) => r,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("invalid path")),
            )
                .into_response();
        }
    };

    // Create the directory if missing; reject if it exists as a file.
    match tokio::fs::try_exists(&resolved).await {
        Ok(true) => match tokio::fs::metadata(&resolved).await {
            Ok(meta) if !meta.is_dir() => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new("path is not a directory")),
                )
                    .into_response();
            }
            Ok(_) => {}
            Err(e) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot access path: {e}"))),
                )
                    .into_response();
            }
        },
        Ok(false) => {
            if let Err(e) = tokio::fs::create_dir_all(&resolved).await {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot create directory: {e}"))),
                )
                    .into_response();
            }
        }
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new(format!("cannot check path: {e}"))),
            )
                .into_response();
        }
    }

    let final_path = match tokio::fs::canonicalize(&resolved).await {
        Ok(c) => c,
        Err(_) => resolved,
    };
    let path = final_path.to_string_lossy().to_string();

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
