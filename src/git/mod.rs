//! Git support: branch listing, worktrees, repository detection, and
//! host authentication.

pub mod clone;
pub mod remote;
pub mod service;

pub use clone::{clone_repo, CloneError, ParsedRemote};
pub use remote::{
    first_gitlab_merge_request_url, parse_gitlab_merge_request_url, parse_gitlab_remote_url,
    GitConnection, GitLabJobLog, GitLabMergeRequestSummary, GitLabPipeline, GitLabPipelineJob,
    GitLabProjectRef, GitLabStatus, GitRemoteService, LinkedMergeRequest, MergeRequestAction,
    RemoteError,
};
pub use service::{
    Branch, ChangeEntry, ChangeList, CommitResult, GitError, GitService, RepoStatus, Worktree,
};
