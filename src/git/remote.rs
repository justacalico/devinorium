//! Git host connection status and authentication via CLI tools (glab, gh).
//!
//! This is intentionally separate from repository-level Git operations in
//! [`service`](super::service). It shells out to the same `glab`/`gh`
//! binaries a user would run by hand, so the backend owns credentials and
//! the frontend never sees or stores tokens.

use std::path::{Path, PathBuf};
use std::time::Duration;

use regex::Regex;
use tokio::process::Command;
use tokio::time::timeout;

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

/// Parsed `glab auth status` for a single host.
#[derive(Debug, Clone)]
pub struct GitLabStatus {
    pub host: String,
    pub authed: bool,
    pub account: Option<String>,
}

/// Manages `glab` authentication state by shelling out to the CLI.
#[derive(Clone)]
pub struct GitRemoteService {
    config_root: PathBuf,
    glab_bin: Option<PathBuf>,
}

impl GitRemoteService {
    /// Build a new service using the `glab` binary on PATH.
    pub fn new(config_root: impl Into<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin: which::which("glab").ok(),
        }
    }

    /// Build a service with an explicit `glab` path, useful in tests.
    pub fn with_glab_bin(config_root: impl Into<PathBuf>, glab_bin: Option<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
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

    /// Authenticate with GitLab using a personal access token.
    pub async fn login_gitlab(
        &self,
        user_id: i64,
        token: &str,
        hostname: Option<&str>,
    ) -> Result<GitLabStatus, RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let host = hostname.unwrap_or("gitlab.com");

        self.run(user_id, bin, &[
            "config", "set", "api_protocol", "https", "--host", host, "--global",
        ])
        .await?;
        self.run(user_id, bin, &[
            "config", "set", "git_protocol", "https", "--host", host, "--global",
        ])
        .await?;
        self.run(user_id, bin, &[
            "config", "set", "api_host", host, "--host", host, "--global",
        ])
        .await?;
        self.run(user_id, bin, &[
            "config", "set", "token", token, "--host", host, "--global",
        ])
        .await?;

        let status = self.gitlab_status_for_host(user_id, host).await?;
        if status.authed {
            Ok(status)
        } else {
            // Don't leave an invalid token lying around.
            let _ = self
                .run(
                    user_id,
                    bin,
                    &["config", "set", "token", "", "--host", host, "--global"],
                )
                .await;
            Err(RemoteError::LoginFailed(
                "token was not accepted by GitLab".into(),
            ))
        }
    }

    /// Log out of a GitLab host.
    pub async fn logout_gitlab(
        &self,
        user_id: i64,
        hostname: Option<&str>,
    ) -> Result<(), RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let host = hostname.unwrap_or("gitlab.com");

        let _ = self
            .run(user_id, bin, &["auth", "logout", "--hostname", host])
            .await;
        let _ = self
            .run(
                user_id,
                bin,
                &["config", "set", "token", "", "--host", host, "--global"],
            )
            .await;

        // Verify the logout took effect.
        let after = self.gitlab_status_for_host(user_id, host).await?;
        if after.authed {
            return Err(RemoteError::LogoutFailed(format!(
                "still logged in as {}",
                after.account.unwrap_or_default()
            )));
        }
        Ok(())
    }

    /// Return the first available GitLab status. Used for the connections list.
    pub async fn gitlab_status(&self, user_id: i64) -> Result<GitLabStatus, RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self
            .run_raw(user_id, bin, &["auth", "status"])
            .await?;
        Self::parse_gitlab_status(&output)
    }

    async fn gitlab_status_for_host(
        &self,
        user_id: i64,
        host: &str,
    ) -> Result<GitLabStatus, RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self
            .run_raw(user_id, bin, &["auth", "status", "--hostname", host])
            .await?;
        Self::parse_gitlab_status(&output)
    }

    fn parse_gitlab_status(output: &str) -> Result<GitLabStatus, RemoteError> {
        static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let re = RE.get_or_init(|| {
            Regex::new(r"(?:[✓✗xX!]\s+)?Logged in to\s+(\S+)\s+as\s+(\S+)")
                .unwrap()
        });

        if let Some(caps) = re.captures(output) {
            return Ok(GitLabStatus {
                host: caps[1].to_string(),
                authed: true,
                account: Some(caps[2].to_string()),
            });
        }

        // No explicit "Logged in" line; try to extract the configured host.
        for line in output.lines().map(str::trim) {
            if line.is_empty() {
                continue;
            }
            // glab prefixes status lines with these markers; the host line
            // is the first unmarked, non-whitespace line.
            if line.starts_with('✓')
                || line.starts_with('✗')
                || line.starts_with('x')
                || line.starts_with('X')
                || line.starts_with('!')
                || line.starts_with("- ")
                || line.starts_with("ERROR")
                || line.starts_with("could not")
            {
                continue;
            }
            // Hosts look like hostnames; reject obvious noise.
            if line.contains(' ') || line.contains('\n') {
                continue;
            }
            return Ok(GitLabStatus {
                host: line.to_string(),
                authed: false,
                account: None,
            });
        }

        Err(RemoteError::StatusFailed(
            "could not parse glab auth status output".into(),
        ))
    }

    /// Run a glab/gh command and treat non-zero exit as an error.
    async fn run(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
    ) -> Result<String, RemoteError> {
        let (output, success) = self.run_raw(user_id, bin, args).await?;
        if !success {
            let msg = output.trim();
            let msg = if msg.is_empty() { "command failed" } else { msg };
            return Err(RemoteError::StatusFailed(msg.to_string()));
        }
        Ok(output)
    }

    /// Run a glab/gh command and return the combined output plus success.
    async fn run_raw(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
    ) -> Result<(String, bool), RemoteError> {
        let mut cmd = self.env_cmd(user_id, bin)?;
        cmd.args(args);

        let output = timeout(Duration::from_secs(30), cmd.output())
            .await
            .map_err(|_| RemoteError::Timeout)?
            .map_err(|e| RemoteError::StatusFailed(e.to_string()))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let combined = format!("{stdout}\n{stderr}");
        Ok((combined, output.status.success()))
    }

    fn env_cmd(&self, user_id: i64, bin: &Path) -> Result<Command, RemoteError> {
        let user_dir = self.config_root.join("glab").join(user_id.to_string());
        let xdg_config = user_dir.join(".config");
        std::fs::create_dir_all(&xdg_config)
            .map_err(|e| RemoteError::StatusFailed(format!("config dir failed: {e}")))?;

        let mut cmd = Command::new(bin);
        cmd.current_dir(&user_dir)
            .env("HOME", &user_dir)
            .env("XDG_CONFIG_HOME", &xdg_config)
            .env("GLAB_CHECK_UPDATE", "false")
            .env("GLAB_NO_PROMPT", "true")
            .env("NO_COLOR", "1")
            .env(
                "USER",
                std::env::var("USER").unwrap_or_else(|_| user_id.to_string()),
            )
            .env(
                "LOGNAME",
                std::env::var("LOGNAME").unwrap_or_else(|_| user_id.to_string()),
            )
            .env("PATH", std::env::var("PATH").unwrap_or_default());

        for key in [
            "GITLAB_TOKEN",
            "GITLAB_ACCESS_TOKEN",
            "OAUTH_TOKEN",
            "GLAB_TOKEN",
        ] {
            cmd.env_remove(key);
        }

        Ok(cmd)
    }
}
