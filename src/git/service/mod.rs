//! Git command execution, caching, and output parsing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use mini_moka::sync::Cache;
use tokio::sync::Mutex;

pub mod branch;
pub mod changes;
pub mod diff;
pub mod runner;
pub mod status;
pub mod sync;
pub mod worktree;

pub use branch::Branch;
pub use changes::{ChangeEntry, ChangeList, CommitResult};
pub use status::RepoStatus;
pub use worktree::Worktree;

/// Time-to-live for cached branch/ref snapshots.
const BRANCH_CACHE_TTL: Duration = Duration::from_secs(120);
/// TTL for repository detection and tracking counts.
const REPO_CACHE_TTL: Duration = Duration::from_secs(300);
/// Cache capacity to avoid memory bloat.
const CACHE_CAPACITY: u64 = 256;

/// Possible errors from Git operations.
#[derive(Debug, thiserror::Error)]
pub enum GitError {
    #[error("git support is not enabled on this backend")]
    NotEnabled,
    #[error("not a git repository")]
    NotRepo,
    #[error("timeout")]
    Timeout,
    #[error("{0}")]
    Other(String),
}

impl GitError {
    pub fn status_code(&self) -> axum::http::StatusCode {
        match self {
            GitError::NotEnabled | GitError::NotRepo => axum::http::StatusCode::NOT_FOUND,
            GitError::Timeout => axum::http::StatusCode::GATEWAY_TIMEOUT,
            GitError::Other(_) => axum::http::StatusCode::BAD_REQUEST,
        }
    }
}

/// Shared Git helper.
#[derive(Clone)]
pub struct GitService {
    pub(super) git: Option<PathBuf>,
    pub(super) repo_cache: Cache<String, RepoStatus>,
    pub(super) branch_cache: Cache<String, Vec<Branch>>,
    pub(super) worktree_cache: Cache<String, Vec<Worktree>>,
    /// Per-thread lock so only one worktree is created on a thread's first send.
    pub(super) worktree_creation_locks: Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>,
}

impl Default for GitService {
    fn default() -> Self {
        Self::new()
    }
}

impl GitService {
    /// Look up the `git` binary. If none is on PATH, all operations return
    /// `GitError::NotEnabled`.
    pub fn new() -> Self {
        let git = which::which("git").ok();
        Self {
            git,
            repo_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(REPO_CACHE_TTL)
                .build(),
            branch_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(BRANCH_CACHE_TTL)
                .build(),
            worktree_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(BRANCH_CACHE_TTL)
                .build(),
            worktree_creation_locks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Return a per-thread lock. Callers should `.lock().await` on the
    /// returned mutex while creating a worktree for the thread.
    pub async fn worktree_creation_lock(&self, thread_id: &str) -> Arc<Mutex<()>> {
        let mut map = self.worktree_creation_locks.lock().await;
        map.entry(thread_id.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    pub fn is_enabled(&self) -> bool {
        self.git.is_some()
    }

    /// Return the path to the `git` binary, if one was found on PATH.
    pub fn binary(&self) -> Option<&Path> {
        self.git.as_deref()
    }

    pub(super) fn invalidate(&self, path: &Path) {
        let key = path.to_string_lossy().to_string();
        self.repo_cache.invalidate(&key);
        self.branch_cache.invalidate(&key);
        self.worktree_cache.invalidate(&key);
    }
}
