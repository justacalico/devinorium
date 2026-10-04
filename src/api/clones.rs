//! Repository clone API.
//!
//! `POST /api/clones` accepts a remote URL, clones it into the owner's
//! configured clone root, creates a project row, and returns the local path.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::git::{clone_repo, CloneError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/clones", post(clone))
}

#[derive(Debug, Deserialize)]
pub struct CloneRequest {
    pub url: String,
    /// Group the new project joins; must belong to the caller.
    pub group_id: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct CloneResponse {
    pub path: String,
}

async fn clone(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CloneRequest>,
) -> Response {
    let url = req.url.trim();
    if url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("url is required")),
        )
            .into_response();
    }

    if let Some(gid) = req.group_id {
        match state.db.get_project_group(gid, user.id).await {
            Ok(Some(_)) => {}
            Ok(None) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("group not found")),
                )
                    .into_response()
            }
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        }
    }

    match clone_repo(
        &state.git,
        &state.git_remote,
        &state.db,
        &state.config,
        user.id,
        user.is_owner,
        url,
        req.group_id,
    )
    .await
    {
        Ok(path) => {
            let path_str = path.to_string_lossy().to_string();
            (StatusCode::CREATED, Json(CloneResponse { path: path_str })).into_response()
        }
        Err(CloneError::NotEnabled) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new(
                "git support is not enabled on this backend",
            )),
        )
            .into_response(),
        Err(e) => {
            let status = e.status_code();
            let msg = e.to_string();
            (status, Json(crate::api::ApiError::new(msg))).into_response()
        }
    }
}
