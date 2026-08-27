//! Git support: branch listing, worktrees, repository detection, and
//! host authentication.

pub mod clone;
pub mod remote;
pub mod service;

pub use clone::{clone_repo, CloneError, ParsedRemote};
pub use remote::{
    parse_gitlab_remote_url, GitConnection, GitLabMergeRequestSummary, GitLabPipeline,
    GitLabProjectRef, GitLabStatus, GitRemoteService, MergeRequestAction, RemoteError,
};
pub use service::{Branch, GitError, GitService, RepoStatus, Worktree};
