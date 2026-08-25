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

    let p = Path::new(path);
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

    // Create the directory if missing; reject if it exists as a file.
    match tokio::fs::try_exists(p).await {
        Ok(true) => match tokio::fs::metadata(p).await {
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
            if let Err(e) = tokio::fs::create_dir_all(p).await {
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

    if let Err(e) = state.db.set_clone_root(user.id, Some(path)).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "clone_root.set",
            &serde_json::json!({"path": path}),
            None,
        )
        .await;

    Json(CloneRootResponse {
        path: Some(path.to_string()),
    })
    .into_response()
}
