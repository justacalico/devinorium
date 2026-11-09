//! Git support: branch listing, worktrees, repository detection, and
//! host authentication.

pub mod clone;
pub mod remote;
pub mod service;

pub use clone::{clone_repo, CloneError, ParsedRemote};
pub use remote::{
    detect_remote, first_github_pull_request_url, first_gitlab_merge_request_url,
    first_merge_request_url, is_github_hostname, parse_git_remote_url,
    parse_github_pull_request_url, parse_github_remote_url, parse_gitlab_merge_request_url,
    GitConnection, GitHost, GitHostStatus, GitRemoteService, LinkedMergeRequest,
    MergeRequestAction, MergeRequestSummary, RemoteError, RemoteIssueSummary, RemoteJobLog,
    RemotePipeline, RemotePipelineJob, RemoteProjectRef,
};
pub use service::{
    Branch, ChangeEntry, ChangeList, CommitEntry, CommitPage, CommitResult, GitError, GitService,
    RepoStatus, Worktree,
};
