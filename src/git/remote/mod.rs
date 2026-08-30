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
pub mod merge_requests;
pub mod parse;
pub mod pipelines;

pub use auth::GitLabStatus;
pub use merge_requests::{GitLabMergeRequestSummary, MergeRequestAction};
pub use parse::{parse_gitlab_remote_url, GitLabProjectRef};
pub use pipelines::{GitLabPipeline, GitLabPipelineJob};

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

/// Manages `glab` authentication state by shelling out to the CLI.
#[derive(Clone)]
pub struct GitRemoteService {
    pub(super) config_root: PathBuf,
    pub(super) glab_bin: Option<PathBuf>,
    pub(super) isolated: bool,
    pub(super) merge_timeout: Duration,
    pub(super) poll_interval: Duration,
}

impl GitRemoteService {
    /// Build a new service using the `glab` binary on PATH and the user's
    /// global glab configuration.
    pub fn new(config_root: impl Into<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin: which::which("glab").ok(),
            isolated: false,
            merge_timeout: Duration::from_secs(120),
            poll_interval: Duration::from_secs(3),
        }
    }

    /// Build a service with an explicit `glab` path, useful in tests.
    /// Tests use an isolated config directory.
    pub fn with_glab_bin(config_root: impl Into<PathBuf>, glab_bin: Option<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
            isolated: true,
            merge_timeout: Duration::from_secs(120),
            poll_interval: Duration::from_secs(3),
        }
    }

    /// Build a service with explicit `glab` path and timeouts. Useful in tests
    /// to exercise the timeout and polling paths without real multi-minute waits.
    pub fn with_glab_bin_and_timeouts(
        config_root: impl Into<PathBuf>,
        glab_bin: Option<PathBuf>,
        merge_timeout: Duration,
        poll_interval: Duration,
    ) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
            isolated: true,
            merge_timeout,
            poll_interval,
        }
    }

    /// Return connection status for every supported Git host.
    pub async fn connections(&self, user_id: i64) -> Vec<GitConnection> {
        let gitlab = match self.gitlab_status(user_id).await {
            Ok(status) => GitConnection {
                id: "gitlab",
                name: "GitLab",
                enabled: self.glab_bin.is_some(),
                available: true,
                authed: status.authed,
                account: status.account,
                host: Some(status.host),
                coming_soon: false,
            },
            Err(RemoteError::GitLabNotAvailable) => GitConnection {
                id: "gitlab",
                name: "GitLab",
                enabled: false,
                available: true,
                authed: false,
                account: None,
                host: None,
                coming_soon: false,
            },
            Err(_) => GitConnection {
                id: "gitlab",
                name: "GitLab",
                enabled: self.glab_bin.is_some(),
                available: true,
                authed: false,
                account: None,
                host: None,
                coming_soon: false,
            },
        };

        let github = GitConnection {
            id: "github",
            name: "GitHub",
            enabled: false,
            available: false,
            authed: false,
            account: None,
            host: None,
            coming_soon: true,
        };

        vec![gitlab, github]
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
        assert_eq!(svc.merge_timeout, Duration::from_secs(120));
        assert_eq!(svc.poll_interval, Duration::from_secs(3));
    }
}
