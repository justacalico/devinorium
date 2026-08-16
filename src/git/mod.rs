//! Git support: branch listing, worktrees, and repository detection.

pub mod service;

pub use service::{Branch, GitError, GitService, RepoStatus, Worktree};
