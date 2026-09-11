//! Git branches, worktree, and working-tree change API routes.
//!
//! Every handler resolves a working directory: the project root by default,
//! or the thread's worktree when a `thread_id` names a thread running in
//! worktree mode (the same scoping rule the file API uses).

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
        .route("/api/projects/:id/git/pull", post(pull))
        .route("/api/projects/:id/git/branches/pull", post(pull_branch))
        .route("/api/projects/:id/git/push", post(push))
        .route("/api/projects/:id/git/worktrees", get(list_worktrees))
        .route("/api/projects/:id/git/worktrees", post(create_worktree))
        .route("/api/projects/:id/git/worktrees", delete(delete_worktree))
        .route("/api/projects/:id/git/status", get(status_summary))
        .route("/api/projects/:id/git/changes", get(changes))
        .route("/api/projects/:id/git/stage", post(stage))
        .route("/api/projects/:id/git/unstage", post(unstage))
        .route("/api/projects/:id/git/commit", post(commit))
        .route(
            "/api/projects/:id/git/merge-request",
            get(merge_request_for_branch),
        )
}

#[derive(Debug, Deserialize)]
pub struct BranchQuery {
    pub query: Option<String>,
    #[serde(default = "default_limit")]
    pub limit: usize,
    pub cursor: Option<String>,
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RepoQuery {
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

fn default_limit() -> usize {
    100
}

/// Resolve the directory git commands run in for a request.
///
/// A non-empty `thread_id` takes precedence over the project: the root
/// becomes the thread's working directory — its worktree in worktree mode,
/// or the project root otherwise — matching the file API's scoping.
async fn repo_path(
    state: &AppState,
    user_id: i64,
    project_id: i64,
    thread_id: Option<&str>,
) -> Result<PathBuf, Response> {
    if let Some(tid) = thread_id.map(str::trim).filter(|s| !s.is_empty()) {
        return match state.db.get_thread(tid, user_id).await {
            Ok(Some(t)) => {
                // A thread with no project — or whose project row was
                // deleted — would fall back to the home dir, where git
                // mutations must never run. Reject instead.
                let project_exists = match t.project_id {
                    Some(pid) => {
                        matches!(state.db.get_project(pid, user_id).await, Ok(Some(_)))
                    }
                    None => false,
                };
                if !project_exists {
                    return Err((
                        StatusCode::BAD_REQUEST,
                        Json(crate::api::ApiError::new("invalid thread_id")),
                    )
                        .into_response());
                }
                crate::api::threads::plan::project_working_dir_for_thread(state, &t)
                    .await
                    .map_err(|e| crate::api::map_err_internal(e).into_response())
            }
            _ => Err((
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid thread_id")),
            )
                .into_response()),
        };
    }
    match state.db.get_project(project_id, user_id).await {
        Ok(Some(p)) => Ok(PathBuf::from(&p.path)),
        _ => Err((
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("project not found")),
        )
            .into_response()),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateBranchRequest {
    pub name: String,
    pub base: Option<String>,
    #[serde(default)]
    pub switch: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CheckoutRequest {
    pub ref_name: String,
    #[serde(default)]
    pub track: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateWorktreeRequest {
    pub name: String,
    pub base: String,
    #[serde(default)]
    pub new_branch: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DeleteWorktreeRequest {
    pub worktree_path: String,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PullBranchRequest {
    pub name: String,
    #[serde(default)]
    pub thread_id: Option<String>,
}

/// Optional body for pull/push so the action can run inside a worktree.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct ScopedRequest {
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct StageRequest {
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub all: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CommitRequest {
    pub message: String,
    #[serde(default)]
    pub all: bool,
    #[serde(default)]
    pub thread_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct MergeRequestQuery {
    pub branch: Option<String>,
    pub iid: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct RepoStatusOut {
    pub is_repo: bool,
    pub branch: String,
    pub worktree_path: String,
    pub toplevel: String,
    pub common_dir: String,
    pub ahead: i64,
    pub behind: i64,
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
    Query(q): Query<RepoQuery>,
) -> Response {
    let path = match repo_path(&state, user.id, id, q.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.repo_status(path.as_path(), q.force).await {
        Ok(s) => Json(RepoStatusOut {
            is_repo: s.is_repo,
            branch: s.branch,
            worktree_path: s.worktree_path.to_string_lossy().to_string(),
            toplevel: s.toplevel.to_string_lossy().to_string(),
            common_dir: s.common_dir.to_string_lossy().to_string(),
            ahead: s.ahead,
            behind: s.behind,
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
    Query(q): Query<RepoQuery>,
) -> Response {
    let path = match repo_path(&state, user.id, id, q.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.status(path.as_path(), q.force).await {
        Ok(v) => Json(v).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn changes(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<RepoQuery>,
) -> Response {
    let path = match repo_path(&state, user.id, id, q.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.changes(path.as_path(), q.force).await {
        Ok(v) => Json(v).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn stage(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<StageRequest>,
) -> Response {
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.stage(path.as_path(), &req.paths, req.all).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn unstage(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<StageRequest>,
) -> Response {
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.unstage(path.as_path(), &req.paths, req.all).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn commit(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<CommitRequest>,
) -> Response {
    if req.message.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("commit message is required")),
        )
            .into_response();
    }
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state
        .git
        .commit(path.as_path(), &req.message, req.all)
        .await
    {
        Ok(r) => Json(r).into_response(),
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
    let path = match repo_path(&state, user.id, id, q.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state
        .git
        .branches(
            path.as_path(),
            q.query.as_deref(),
            Some(q.limit),
            q.force,
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
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("branch name is required")),
        )
            .into_response();
    }
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state
        .git
        .create_branch(path.as_path(), name, req.base.as_deref(), req.switch)
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
    let ref_name = req.ref_name.trim();
    if ref_name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("ref name is required")),
        )
            .into_response();
    }
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.checkout(path.as_path(), ref_name, req.track).await {
        Ok(name) => Json(serde_json::json!({"name": name})).into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn pull(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    body: Option<Json<ScopedRequest>>,
) -> Response {
    let thread_id = body.and_then(|b| b.0.thread_id);
    let path = match repo_path(&state, user.id, id, thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.pull(path.as_path()).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn pull_branch(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<PullBranchRequest>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("branch name is required")),
        )
            .into_response();
    }
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.pull_branch(path.as_path(), name).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn push(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    body: Option<Json<ScopedRequest>>,
) -> Response {
    let thread_id = body.and_then(|b| b.0.thread_id);
    let path = match repo_path(&state, user.id, id, thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.push(path.as_path()).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(GitError::NotEnabled) => not_enabled(),
        Err(GitError::NotRepo) => not_repo(),
        Err(e) => error_response(e),
    }
}

async fn list_worktrees(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<RepoQuery>,
) -> Response {
    let path = match repo_path(&state, user.id, id, q.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state.git.worktrees(path.as_path(), q.force).await {
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
    let name = req.name.trim();
    let base = req.base.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("worktree name is required")),
        )
            .into_response();
    }
    if base.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("base branch is required")),
        )
            .into_response();
    }
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state
        .git
        .create_worktree(path.as_path(), name, base, req.new_branch)
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
    let path = match repo_path(&state, user.id, id, req.thread_id.as_deref()).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    match state
        .git
        .remove_worktree(
            path.as_path(),
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

/// Find a merge request linked to the project.
///
/// Resolves the project's git remote URL to a GitLab project. With `branch`,
/// returns the open MR for that source branch. With `iid`, returns the MR with
/// that IID regardless of state. Returns the MR summary, `204` when no MR
/// exists, or an error when the project is not a GitLab repository or glab is
/// unavailable.
async fn merge_request_for_branch(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Query(mut q): Query<MergeRequestQuery>,
) -> Response {
    if q.branch
        .as_deref()
        .map(str::trim)
        .is_some_and(|s| s.is_empty())
    {
        q.branch = None;
    }
    if q.branch.is_none() && q.iid.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("branch or iid is required")),
        )
            .into_response();
    }
    if q.branch.is_some() && q.iid.is_some() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new(
                "branch and iid cannot both be set",
            )),
        )
            .into_response();
    }

    let path = match repo_path(&state, user.id, id, None).await {
        Ok(p) => p,
        Err(r) => return r,
    };

    let url = match state.git.remote_url(path.as_path()).await {
        Ok(url) => url,
        Err(GitError::NotEnabled) => return not_enabled(),
        Err(GitError::NotRepo) => return not_repo(),
        Err(e) => return error_response(e),
    };

    let gitlab = match crate::git::parse_gitlab_remote_url(&url) {
        Some(g) => g,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new(
                    "project remote is not a GitLab repository",
                )),
            )
                .into_response()
        }
    };

    let result = if let Some(iid) = q.iid {
        state
            .git_remote
            .gitlab_merge_request(user.id, &gitlab.hostname, &gitlab.project_path, iid)
            .await
            .map(Some)
    } else {
        let branch = q.branch.as_deref().unwrap_or("");
        state
            .git_remote
            .gitlab_merge_request_for_branch(
                user.id,
                &gitlab.hostname,
                &gitlab.project_path,
                branch,
            )
            .await
    };

    match result {
        Ok(Some(mr)) => Json(mr).into_response(),
        Ok(None) => StatusCode::NO_CONTENT.into_response(),
        Err(crate::git::RemoteError::GitLabNotAvailable) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("gitlab cli is not installed")),
        )
            .into_response(),
        Err(e) => (
            e.status_code(),
            Json(crate::api::ApiError::new(e.to_string())),
        )
            .into_response(),
    }
}

fn not_enabled() -> Response {
    (
        StatusCode::NOT_FOUND,
        Json(crate::api::ApiError::new(
            "git support is not enabled on this backend",
        )),
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
        Json(crate::api::ApiError::new(e.to_string())),
    )
        .into_response()
}
