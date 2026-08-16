//! Git support: branch listing, worktrees, repository detection, and
//! host authentication.

pub mod remote;
pub mod service;

pub use remote::{GitConnection, GitLabStatus, GitRemoteService, RemoteError};
pub use service::{Branch, GitError, GitService, RepoStatus, Worktree};
