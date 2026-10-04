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
    /// Paired node to clone on; absent or `local` clones on this server.
    #[serde(default)]
    pub node_id: Option<String>,
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

    if let Some(nid) = req
        .node_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        // The satellite owns the clone and reports the path back; the hub
        // only writes the project row against the node.
        return match clone_remote(&state, &user, nid, url).await {
            Ok(path) => (
                StatusCode::CREATED,
                Json(CloneResponse {
                    path: path.to_string_lossy().to_string(),
                }),
            )
                .into_response(),
            Err(CloneError::NotEnabled) => (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new(
                    "git support is not enabled on this backend",
                )),
            )
                .into_response(),
            Err(e) => {
                let status = e.status_code();
                (status, Json(crate::api::ApiError::new(e.to_string()))).into_response()
            }
        };
    }

    match clone_repo(
        &state.git,
        &state.git_remote,
        &state.db,
        &state.config,
        user.id,
        user.is_owner,
        url,
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

/// Clone a remote on a paired satellite and record the project row.
async fn clone_remote(
    state: &AppState,
    user: &crate::db::UserRow,
    node_id: &str,
    url: &str,
) -> Result<std::path::PathBuf, CloneError> {
    if !user.is_owner {
        return Err(CloneError::MalformedUrl);
    }
    let node = state
        .db
        .get_federation_node(node_id)
        .await
        .ok()
        .flatten()
        .ok_or(CloneError::NotEnabled)?;
    let client = crate::node_client::NodeClient::for_node(state, &node)
        .ok_or(CloneError::NotEnabled)?
        .with_proxy_user(&user.username);
    let parsed = crate::git::clone::parse_remote_url(url)?;
    let path = client
        .clone_repo(url)
        .await
        .map_err(|e| CloneError::CloneFailed(e.to_string()))?;
    // Any failure below leaves an orphaned clone on the satellite; try to
    // remove it before reporting the error.
    let cleanup = |client: &crate::node_client::NodeClient, path: &str| {
        let client = client.clone();
        let path = path.to_string();
        async move {
            let _ = client.fs_delete(None, &path).await;
        }
    };
    let path_buf = std::path::PathBuf::from(&path);
    if state
        .db
        .get_project_by_path(user.id, &path)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?
        .is_some()
    {
        cleanup(&client, &path).await;
        return Err(CloneError::AlreadyExists);
    }
    let project_name =
        crate::git::clone::unique_project_name(&state.db, user.id, &parsed.owner, &parsed.repo)
            .await?;
    let position = state
        .db
        .next_project_position(user.id)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?;
    if let Err(e) = state
        .db
        .create_project(crate::db::NewProject {
            user_id: user.id,
            name: project_name,
            path: path_buf.to_string_lossy().to_string(),
            position,
            project_type: "git".into(),
            node_id: Some(node.id.clone()),
        })
        .await
    {
        cleanup(&client, &path).await;
        return Err(CloneError::CloneFailed(e.to_string()));
    }
    Ok(path_buf)
}
