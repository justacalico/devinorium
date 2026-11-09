//! Git host connection status and authentication via CLI tools (glab, gh).
//!
//! This is intentionally separate from repository-level Git operations in
//! [`service`](super::service). It shells out to the same `glab`/`gh`
//! binaries a user would run by hand, so the backend owns credentials and
//! the frontend never sees or stores tokens.

use std::path::PathBuf;
use std::time::Duration;

pub mod api_client;
pub mod auth;
pub mod issues;
pub mod merge_requests;
pub mod parse;
pub mod pipelines;

pub use auth::GitHostStatus;
pub use issues::RemoteIssueSummary;
pub use merge_requests::{MergeRequestAction, MergeRequestSummary};
pub use parse::{
    detect_remote, first_github_pull_request_url, first_gitlab_merge_request_url,
    first_merge_request_url, is_github_hostname, parse_git_remote_url,
    parse_github_pull_request_url, parse_github_remote_url, parse_gitlab_merge_request_url,
    LinkedMergeRequest, RemoteProjectRef,
};
pub use pipelines::{RemoteJobLog, RemotePipeline, RemotePipelineJob};

/// Possible errors from Git host CLI operations.
#[derive(Debug, thiserror::Error)]
pub enum RemoteError {
    #[error("gitlab cli is not installed")]
    GitLabNotAvailable,
    #[error("github cli is not installed")]
    GitHubNotAvailable,
    #[error("login failed: {0}")]
    LoginFailed(String),
    #[error("logout failed: {0}")]
    LogoutFailed(String),
    #[error("status check failed: {0}")]
    StatusFailed(String),
    #[error("timeout")]
    Timeout,
}

impl RemoteError {
    pub fn status_code(&self) -> axum::http::StatusCode {
        use axum::http::StatusCode;
        match self {
            RemoteError::GitLabNotAvailable | RemoteError::GitHubNotAvailable => {
                StatusCode::NOT_FOUND
            }
            RemoteError::Timeout => StatusCode::GATEWAY_TIMEOUT,
            _ => StatusCode::BAD_REQUEST,
        }
    }
}

/// The git host a remote URL or connection belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GitHost {
    GitLab,
    GitHub,
}

impl GitHost {
    pub fn id(self) -> &'static str {
        match self {
            GitHost::GitLab => "gitlab",
            GitHost::GitHub => "github",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            GitHost::GitLab => "GitLab",
            GitHost::GitHub => "GitHub",
        }
    }

    pub fn default_hostname(self) -> &'static str {
        match self {
            GitHost::GitLab => "gitlab.com",
            GitHost::GitHub => "github.com",
        }
    }

    pub fn not_available_error(self) -> RemoteError {
        match self {
            GitHost::GitLab => RemoteError::GitLabNotAvailable,
            GitHost::GitHub => RemoteError::GitHubNotAvailable,
        }
    }

    /// The provider a remote hostname belongs to. GitHub cloud and
    /// Enterprise Cloud (`*.ghe.com`) domains are detected; every other host
    /// is treated as GitLab, matching the pre-GitHub behaviour where any
    /// hostname could be a self-managed GitLab instance.
    pub fn for_hostname(hostname: &str) -> GitHost {
        if is_github_hostname(hostname) {
            GitHost::GitHub
        } else {
            GitHost::GitLab
        }
    }
}

/// Which git host CLI a subprocess invocation runs through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CliKind {
    Glab,
    Gh,
}

impl CliKind {
    /// The per-user config subdirectory used when the service runs isolated.
    fn config_dir_name(self) -> &'static str {
        match self {
            CliKind::Glab => "glab",
            CliKind::Gh => "gh",
        }
    }
}

/// A connection to a Git host as shown in the settings UI.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitConnection {
    pub id: &'static str,
    pub name: &'static str,
    pub enabled: bool,
    pub available: bool,
    pub authed: bool,
    pub account: Option<String>,
    pub host: Option<String>,
    pub coming_soon: bool,
}

/// Manages `glab`/`gh` authentication state by shelling out to the CLIs.
#[derive(Clone)]
pub struct GitRemoteService {
    pub(super) config_root: PathBuf,
    pub(super) glab_bin: Option<PathBuf>,
    pub(super) gh_bin: Option<PathBuf>,
    pub(super) isolated: bool,
    pub(super) merge_timeout: Duration,
    pub(super) poll_interval: Duration,
}

impl GitRemoteService {
    /// Build a new service using the `glab` and `gh` binaries on PATH and
    /// the user's global CLI configuration.
    pub fn new(config_root: impl Into<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin: which::which("glab").ok(),
            gh_bin: which::which("gh").ok(),
            isolated: false,
            merge_timeout: Duration::from_secs(120),
            poll_interval: Duration::from_secs(3),
        }
    }

    /// Build a service with an explicit `glab` path, useful in tests.
    /// Tests use an isolated config directory.
    pub fn with_glab_bin(config_root: impl Into<PathBuf>, glab_bin: Option<PathBuf>) -> Self {
        Self::with_bins(config_root, glab_bin, None)
    }

    /// Build a service with explicit `glab` and `gh` paths, useful in tests.
    /// Tests use an isolated config directory.
    pub fn with_bins(
        config_root: impl Into<PathBuf>,
        glab_bin: Option<PathBuf>,
        gh_bin: Option<PathBuf>,
    ) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
            gh_bin,
            isolated: true,
            merge_timeout: Duration::from_secs(120),
            poll_interval: Duration::from_secs(3),
        }
    }

    /// Build a service with explicit `glab`/`gh` paths and timeouts. Useful
    /// in tests to exercise the timeout and polling paths without real
    /// multi-minute waits.
    pub fn with_bins_and_timeouts(
        config_root: impl Into<PathBuf>,
        glab_bin: Option<PathBuf>,
        gh_bin: Option<PathBuf>,
        merge_timeout: Duration,
        poll_interval: Duration,
    ) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
            gh_bin,
            isolated: true,
            merge_timeout,
            poll_interval,
        }
    }

    /// Build a service with an explicit `glab` path and timeouts. Useful in
    /// tests to exercise the timeout and polling paths without real
    /// multi-minute waits.
    pub fn with_glab_bin_and_timeouts(
        config_root: impl Into<PathBuf>,
        glab_bin: Option<PathBuf>,
        merge_timeout: Duration,
        poll_interval: Duration,
    ) -> Self {
        Self::with_bins_and_timeouts(config_root, glab_bin, None, merge_timeout, poll_interval)
    }

    /// Return connection status for every supported Git host.
    pub async fn connections(&self, user_id: i64) -> Vec<GitConnection> {
        vec![
            self.connection_for(user_id, GitHost::GitLab).await,
            self.connection_for(user_id, GitHost::GitHub).await,
        ]
    }

    async fn connection_for(&self, user_id: i64, host: GitHost) -> GitConnection {
        let installed = match host {
            GitHost::GitLab => self.glab_bin.is_some(),
            GitHost::GitHub => self.gh_bin.is_some(),
        };
        let status = match host {
            GitHost::GitLab => self.gitlab_status(user_id).await,
            GitHost::GitHub => self.github_status(user_id).await,
        };
        let (authed, account, hostname) = match status {
            Ok(s) => (s.authed, s.account, Some(s.host)),
            Err(_) => (false, None, None),
        };
        GitConnection {
            id: host.id(),
            name: host.display_name(),
            enabled: installed,
            available: true,
            authed,
            account,
            host: hostname,
            coming_soon: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_error_status_codes() {
        use axum::http::StatusCode;
        assert_eq!(
            RemoteError::GitLabNotAvailable.status_code(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            RemoteError::GitHubNotAvailable.status_code(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            RemoteError::Timeout.status_code(),
            StatusCode::GATEWAY_TIMEOUT
        );
        assert_eq!(
            RemoteError::LoginFailed("no".into()).status_code(),
            StatusCode::BAD_REQUEST
        );
    }

    #[test]
    fn with_glab_bin_uses_isolated_config() {
        let svc = GitRemoteService::with_glab_bin("/tmp", Some(PathBuf::from("/bin/glab")));
        assert!(svc.isolated);
        assert_eq!(
            svc.glab_bin.as_deref(),
            Some(std::path::Path::new("/bin/glab"))
        );
        assert!(svc.gh_bin.is_none());
        assert_eq!(svc.merge_timeout, Duration::from_secs(120));
        assert_eq!(svc.poll_interval, Duration::from_secs(3));
    }

    #[test]
    fn with_bins_keeps_both_binaries() {
        let svc = GitRemoteService::with_bins(
            "/tmp",
            Some(PathBuf::from("/bin/glab")),
            Some(PathBuf::from("/bin/gh")),
        );
        assert!(svc.isolated);
        assert_eq!(svc.gh_bin.as_deref(), Some(std::path::Path::new("/bin/gh")));
    }

    #[test]
    fn git_host_detects_github_domains() {
        assert_eq!(GitHost::for_hostname("github.com"), GitHost::GitHub);
        assert_eq!(GitHost::for_hostname("corp.ghe.com"), GitHost::GitHub);
        assert_eq!(GitHost::for_hostname("team.ghe.localhost"), GitHost::GitHub);
        assert_eq!(GitHost::for_hostname("gitlab.com"), GitHost::GitLab);
        assert_eq!(GitHost::for_hostname("gitlab.example.com"), GitHost::GitLab);
    }
}
