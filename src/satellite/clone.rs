//! Satellite clone endpoint: `git clone` into a managed directory.
//!
//! Clones land under `~/.devinorium/clones/<platform>/<owner>/<repo>/`,
//! mirroring the hub's clone-root layout. The hub creates the project row
//! afterwards; the satellite only reports the path back.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use tokio::process::Command;

use crate::git::clone::{parse_remote_url, run_git_clone, CloneError};
use crate::node::{CloneNodeRequest, CloneNodeResponse, NodeError};
use crate::satellite::{internal, SatelliteState};
use crate::security::paths;

pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new().route("/api/node/clone", post(clone))
}

fn clone_error(e: CloneError) -> Response {
    (
        e.status_code(),
        Json(NodeError::new("clone", e.to_string())),
    )
        .into_response()
}

/// The satellite's clone root: `~/.devinorium/clones`.
fn clone_root(state: &SatelliteState) -> std::path::PathBuf {
    state.home_dir.join(".devinorium").join("clones")
}

async fn clone(
    State(state): State<Arc<SatelliteState>>,
    Json(req): Json<CloneNodeRequest>,
) -> Response {
    let parsed = match parse_remote_url(&req.url) {
        Ok(p) => p,
        Err(e) => return clone_error(e),
    };
    let root = clone_root(&state);
    let target = root
        .join(&parsed.platform)
        .join(&parsed.owner)
        .join(&parsed.repo);
    let resolved_target = match paths::resolve(&target, None, Some(std::slice::from_ref(&root))) {
        Some(p) => p,
        None => return clone_error(CloneError::InvalidSegment),
    };
    if tokio::fs::try_exists(&resolved_target)
        .await
        .unwrap_or(false)
    {
        return clone_error(CloneError::AlreadyExists);
    }
    if let Some(parent) = resolved_target.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            return internal(e).into_response();
        }
    }

    let Some(git_bin) = state.git.binary().map(|b| b.to_path_buf()) else {
        return clone_error(CloneError::NotEnabled);
    };
    let mut cmd = Command::new(git_bin);
    cmd.env("LC_ALL", "C")
        .env("GCM_INTERACTIVE", "never")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env("GIT_ASKPASS", "false")
        .env("HOME", &state.home_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .arg("clone")
        .arg("--")
        .arg(&parsed.clean_url)
        .arg(&resolved_target);

    if let Err(e) = run_git_clone(&mut cmd, Duration::from_secs(300)).await {
        let _ = tokio::fs::remove_dir_all(&resolved_target).await;
        return clone_error(e);
    }

    match tokio::fs::canonicalize(&resolved_target).await {
        Ok(p) => Json(CloneNodeResponse {
            path: p.to_string_lossy().to_string(),
        })
        .into_response(),
        Err(e) => internal(e).into_response(),
    }
}
