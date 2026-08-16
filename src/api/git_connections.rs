//! Git host connection settings API.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, Router};
use axum::Json;
use serde::Deserialize;

use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::git::{GitConnection, RemoteError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/git-connections", get(list))
        .route("/api/git-connections/gitlab", post(login_gitlab))
        .route("/api/git-connections/gitlab", delete(logout_gitlab))
}

#[derive(Debug, Deserialize)]
pub struct GitLabLoginRequest {
    pub token: String,
    pub hostname: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct GitLabLogoutRequest {
    pub hostname: Option<String>,
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    let connections = state.git_remote.connections(user.id).await;
    Json(connections).into_response()
}

async fn login_gitlab(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<GitLabLoginRequest>,
) -> Response {
    let token = req.token.trim();
    if token.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("token is required")),
        )
            .into_response();
    }

    let hostname = req
        .hostname
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    match state
        .git_remote
        .login_gitlab(user.id, token, hostname.as_deref())
        .await
    {
        Ok(status) => Json(GitConnection {
            id: "gitlab",
            name: "GitLab",
            enabled: true,
            available: true,
            authed: true,
            account: status.account,
            host: Some(status.host),
            coming_soon: false,
        })
        .into_response(),
        Err(RemoteError::GitLabNotAvailable) => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("gitlab cli is not installed")),
        )
            .into_response(),
        Err(e) => (e.status_code(), Json(ApiError::new(e.to_string()))).into_response(),
    }
}

async fn logout_gitlab(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<GitLabLogoutRequest>,
) -> Response {
    let hostname = req.hostname.as_deref().filter(|s| !s.is_empty());

    match state.git_remote.logout_gitlab(user.id, hostname).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(RemoteError::GitLabNotAvailable) => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("gitlab cli is not installed")),
        )
            .into_response(),
        Err(e) => (e.status_code(), Json(ApiError::new(e.to_string()))).into_response(),
    }
}
