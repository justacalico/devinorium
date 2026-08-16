//! Git branches and worktree API routes.

use std::path::PathBuf;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::git::GitError;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/projects/:id/git", get(status))
        .route("/api/projects/:id/git/branches", get(list_branches))
        .route("/api/projects/:id/git/branches", post(create_branch))
        .route("/api/projects/:id/git/checkout", post(checkout))
        .route("/api/projects/:id/git/worktrees", get(list_worktrees))
        .route("/api/projects/:id/git/worktrees", post(create_worktree))
        .route("/api/projects/:id/git/worktrees", delete(delete_worktree))
        .route("/api/projects/:id/git/status", get(status_summary))
}

#[derive(Debug, Deserialize)]
pub struct BranchQuery {
    pub query: Option<String>,
    #[serde(default = "default_limit")]
    pub limit: usize,
    pub cursor: Option<String>,
}

fn default_limit() -> usize {
    100
}

#[derive(Debug, Deserialize)]
pub struct CreateBranchRequest {
    pub name: String,
    pub base: Option<String>,
    #[serde(default)]
    pub switch: bool,
}

#[derive(Debug, Deserialize)]
pub struct CheckoutRequest {
    pub ref_name: String,
    #[serde(default)]
    pub track: bool,
}

#[derive(Debug, Deserialize)]
pub struct CreateWorktreeRequest {
    pub name: String,
    pub base: String,
    #[serde(default)]
    pub new_branch: bool,
}

#[derive(Debug, Deserialize)]
pub struct DeleteWorktreeRequest {
    pub worktree_path: String,
}

#[derive(Debug, Serialize)]
pub struct RepoStatusOut {
    pub is_repo: bool,
    pub branch: String,
    pub worktree_path: String,
    pub toplevel: String,
    pub common_dir: String,
}

#[derive(Debug, Serialize)]
pub struct BranchesOut {
    pub branches: Vec<crate::git::Branch>,
    pub current: String,
    pub default: String,
}

async fn status(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state.git.repo_status(PathBuf::from(&project.path).as_path()).await {
        Ok(s) => Json(RepoStatusOut {
            is_repo: s.is_repo,
            branch: s.branch,
            worktree_path: s.worktree_path.to_string_lossy().to_string(),
            toplevel: s.toplevel.to_string_lossy().to_string(),
            common_dir: s.common_dir.to_string_lossy().to_string(),
        })
        .into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn status_summary(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state.git.status(PathBuf::from(&project.path).as_path()).await {
        Ok(v) => Json(v).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn list_branches(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<BranchQuery>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state
        .git
        .branches(
            PathBuf::from(&project.path).as_path(),
            q.query.as_deref(),
            Some(q.limit),
        )
        .await
    {
        Ok(branches) => {
            let current = branches
                .iter()
                .find(|b| b.is_current)
                .map(|b| b.name.clone())
                .unwrap_or_default();
            let default = branches
                .iter()
                .find(|b| b.is_default)
                .map(|b| b.name.clone())
                .unwrap_or_default();
            Json(BranchesOut {
                branches,
                current,
                default,
            })
            .into_response()
        }
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn create_branch(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<CreateBranchRequest>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("branch name is required")),
        )
            .into_response();
    }

    match state
        .git
        .create_branch(
            PathBuf::from(&project.path).as_path(),
            name,
            req.base.as_deref(),
            req.switch,
        )
        .await
    {
        Ok(name) => (StatusCode::CREATED, Json(serde_json::json!({"name": name}))).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn checkout(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<CheckoutRequest>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state
        .git
        .checkout(
            PathBuf::from(&project.path).as_path(),
            &req.ref_name,
            req.track,
        )
        .await
    {
        Ok(name) => Json(serde_json::json!({"name": name})).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn list_worktrees(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state.git.worktrees(PathBuf::from(&project.path).as_path()).await {
        Ok(worktrees) => Json(worktrees).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn create_worktree(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<CreateWorktreeRequest>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state
        .git
        .create_worktree(
            PathBuf::from(&project.path).as_path(),
            &req.name,
            &req.base,
            req.new_branch,
        )
        .await
    {
        Ok(w) => (StatusCode::CREATED, Json(w)).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn delete_worktree(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<DeleteWorktreeRequest>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("project not found")),
            )
                .into_response()
        }
    };

    match state
        .git
        .remove_worktree(
            PathBuf::from(&project.path).as_path(),
            PathBuf::from(&req.worktree_path).as_path(),
        )
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

fn not_enabled() -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(crate::api::ApiError::new("git support is not enabled on this backend")),
    )
        .into_response()
}

fn not_repo() -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(crate::api::ApiError::new("not a git repository")),
    )
        .into_response()
}

fn error_response(e: GitError) -> Response {
    (
        e.status_code(),
        Json(crate::api::ApiError::new(&e.to_string())),
    )
        .into_response()
}
