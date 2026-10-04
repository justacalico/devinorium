//! Satellite git endpoint: `GitService` over HTTP.
//!
//! `POST /api/node/git/:method` runs the named [`GitService`] method against
//! `repo` (an absolute path on this machine) and returns the method's
//! result serialized the same way the hub shapes it, so a `RemoteGit`
//! client on the hub behaves identically to the local service.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::extract::{Path as AxumPath, State};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;

use crate::git::{GitError, GitService};
use crate::node::NodeError;
use crate::satellite::{bad_request, SatelliteState};

pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new().route("/api/node/git/:method", post(call))
}

fn git_error(e: GitError) -> Response {
    let kind = match &e {
        GitError::NotEnabled => "not_enabled",
        GitError::NotRepo => "not_repo",
        GitError::Timeout => "timeout",
        GitError::Other(_) => "other",
    };
    (e.status_code(), Json(NodeError::new(kind, e.to_string()))).into_response()
}

/// A git call: `method` names the GitService operation, `repo` is the
/// working directory, and the remaining fields are that method's args.
#[derive(Debug, Deserialize)]
pub struct GitCall {
    #[serde(default)]
    repo: Option<String>,
    #[serde(default)]
    force: bool,
    // changes/diff
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    orig_path: Option<String>,
    #[serde(default)]
    staged: bool,
    // stage/unstage/discard
    #[serde(default)]
    paths: Vec<String>,
    #[serde(default)]
    all: bool,
    // log
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    offset: usize,
    // branches
    #[serde(default)]
    query: Option<String>,
    // branch/checkout
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    base: Option<String>,
    #[serde(default)]
    switch: bool,
    #[serde(default)]
    ref_name: Option<String>,
    #[serde(default)]
    track: bool,
    // commit
    #[serde(default)]
    message: Option<String>,
    // worktrees
    #[serde(default)]
    new_branch: bool,
    #[serde(default)]
    branch: Option<String>,
    #[serde(default)]
    worktree_path: Option<String>,
}

async fn call(
    State(state): State<Arc<SatelliteState>>,
    AxumPath(method): AxumPath<String>,
    Json(req): Json<GitCall>,
) -> Response {
    let repo_str = req.repo.as_deref().unwrap_or("").trim();
    let repo = PathBuf::from(repo_str);
    if repo_str.is_empty() || !repo.is_absolute() {
        return bad_request("repo must be an absolute path");
    }
    match dispatch(&state.git, &method, &repo, &req).await {
        Ok(v) => Json(v).into_response(),
        Err(e) => git_error(e),
    }
}

/// Run the named GitService method against `repo`.
async fn dispatch(
    git: &GitService,
    method: &str,
    repo: &Path,
    req: &GitCall,
) -> Result<serde_json::Value, GitError> {
    macro_rules! val {
        ($e:expr) => {
            serde_json::to_value($e?).unwrap_or_default()
        };
    }
    match method {
        "repo_status" => Ok(val!(git.repo_status(repo, req.force).await)),
        "status" => Ok(val!(git.status(repo, req.force).await)),
        "file_statuses" => Ok(val!(git.file_statuses(repo).await)),
        "changes" => Ok(val!(git.changes(repo, req.force).await)),
        "change_diff" => Ok(val!(
            git.change_diff(
                repo,
                req.path.as_deref().unwrap_or(""),
                req.orig_path.as_deref(),
                req.staged,
                req.force,
            )
            .await
        )),
        "discard" => {
            git.discard(repo, &req.paths, req.staged).await?;
            Ok(serde_json::Value::Null)
        }
        "log" => Ok(val!(
            git.log(repo, req.limit.unwrap_or(30), req.offset, req.force)
                .await
        )),
        "stage" => {
            git.stage(repo, &req.paths, req.all).await?;
            Ok(serde_json::Value::Null)
        }
        "unstage" => {
            git.unstage(repo, &req.paths, req.all).await?;
            Ok(serde_json::Value::Null)
        }
        "commit" => Ok(val!(
            git.commit(repo, req.message.as_deref().unwrap_or(""), req.all)
                .await
        )),
        "branches" => Ok(val!(
            git.branches(repo, req.query.as_deref(), req.limit, req.force)
                .await
        )),
        "create_branch" => Ok(val!(
            git.create_branch(
                repo,
                req.name.as_deref().unwrap_or(""),
                req.base.as_deref(),
                req.switch,
            )
            .await
        )),
        "checkout" => Ok(val!(
            git.checkout(repo, req.ref_name.as_deref().unwrap_or(""), req.track)
                .await
        )),
        "pull" => {
            git.pull(repo).await?;
            Ok(serde_json::Value::Null)
        }
        "pull_branch" => {
            git.pull_branch(repo, req.name.as_deref().unwrap_or(""))
                .await?;
            Ok(serde_json::Value::Null)
        }
        "push" => {
            git.push(repo).await?;
            Ok(serde_json::Value::Null)
        }
        "worktrees" => Ok(val!(git.worktrees(repo, req.force).await)),
        "create_worktree" => Ok(val!(
            git.create_worktree(
                repo,
                req.name.as_deref().unwrap_or(""),
                req.base.as_deref().unwrap_or(""),
                req.new_branch,
            )
            .await
        )),
        "create_worktree_at" => Ok(val!(
            git.create_worktree_at(
                repo,
                req.branch.as_deref().unwrap_or(""),
                req.base.as_deref().unwrap_or(""),
                &PathBuf::from(req.worktree_path.as_deref().unwrap_or("")),
                req.new_branch,
            )
            .await
        )),
        "remove_worktree" => {
            git.remove_worktree(
                repo,
                &PathBuf::from(req.worktree_path.as_deref().unwrap_or("")),
            )
            .await?;
            Ok(serde_json::Value::Null)
        }
        "prune_worktrees" => {
            git.prune_worktrees(repo).await?;
            Ok(serde_json::Value::Null)
        }
        "delete_branch" => {
            git.delete_branch(repo, req.name.as_deref().unwrap_or(""))
                .await?;
            Ok(serde_json::Value::Null)
        }
        "remote_url" => Ok(val!(git.remote_url(repo).await)),
        other => Err(GitError::Other(format!("unknown git method: {other}"))),
    }
}
