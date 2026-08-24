//! Git host connection status and authentication via CLI tools (glab, gh).
//!
//! This is intentionally separate from repository-level Git operations in
//! [`service`](super::service). It shells out to the same `glab`/`gh`
//! binaries a user would run by hand, so the backend owns credentials and
//! the frontend never sees or stores tokens.

use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
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

/// A write action that can be applied to a GitLab merge request.
///
/// The set is deliberately closed so the frontend cannot ask the backend to
/// perform arbitrary mutations through the `glab` proxy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeRequestAction {
    Close,
    Reopen,
    Merge,
    MergeWhenPipelineSucceeds,
}

/// A single CI/CD pipeline for a GitLab merge request.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabPipeline {
    pub status: String,
    pub name: String,
    pub web_url: String,
    pub ref_name: String,
    pub created_at: String,
    pub updated_at: String,
}

/// Manages `glab` authentication state by shelling out to the CLI.
#[derive(Clone)]
pub struct GitRemoteService {
    config_root: PathBuf,
    glab_bin: Option<PathBuf>,
    /// When true, `glab` uses an isolated per-user config directory under
    /// `config_root`. When false, `glab` uses the user's global config (the
    /// default for the production server process).
    isolated: bool,
}

impl GitRemoteService {
    /// Build a new service using the `glab` binary on PATH and the user's
    /// global glab configuration.
    pub fn new(config_root: impl Into<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin: which::which("glab").ok(),
            isolated: false,
        }
    }

    /// Build a service with an explicit `glab` path, useful in tests.
    /// Tests use an isolated config directory.
    pub fn with_glab_bin(config_root: impl Into<PathBuf>, glab_bin: Option<PathBuf>) -> Self {
        Self {
            config_root: config_root.into(),
            glab_bin,
            isolated: true,
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

    /// Verify that `glab` is already authenticated for the given host.
    ///
    /// The user must authenticate via the glab CLI itself
    /// (`glab auth login`); this method only reports the current status.
    pub async fn login_gitlab(
        &self,
        user_id: i64,
        hostname: Option<&str>,
    ) -> Result<GitLabStatus, RemoteError> {
        self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let host = hostname.unwrap_or("gitlab.com");

        let status = self.gitlab_status_for_host(user_id, host).await?;
        if status.authed {
            Ok(status)
        } else {
            Err(RemoteError::LoginFailed(
                "glab is not authenticated for this host; run `glab auth login`".into(),
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

    /// Call the GitLab API through `glab api` for the configured host.
    ///
    /// [path] is a GitLab v4 API path such as
    /// `projects/group%2Fproject/merge_requests/1`. Only `projects/` paths are
    /// allowed to keep the proxy scoped to project data.
    pub async fn gitlab_api(
        &self,
        user_id: i64,
        hostname: &str,
        path: &str,
    ) -> Result<String, RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let host = Self::api_host(hostname);
        Self::check_api_path(path)?;

        self.run(user_id, bin, &["api", path, "--hostname", host]).await
    }

    /// Call the GitLab API with an explicit HTTP method and body fields.
    ///
    /// Fields are passed as `--field key=value`, so `glab` encodes `true`,
    /// `false` and integers as their JSON types.
    async fn gitlab_api_write(
        &self,
        user_id: i64,
        hostname: &str,
        method: &str,
        path: &str,
        fields: &[(&str, &str)],
        timeout: Duration,
    ) -> Result<String, RemoteError> {
        let bin = self.glab_bin.as_ref().ok_or(RemoteError::GitLabNotAvailable)?;
        let host = Self::api_host(hostname);
        Self::check_api_path(path)?;

        let mut args = vec![
            "api".to_string(),
            path.to_string(),
            "--hostname".to_string(),
            host.to_string(),
            "--method".to_string(),
            method.to_string(),
        ];
        for (key, value) in fields {
            // `glab` reads `@file` values from disk; refuse them outright.
            if value.starts_with('@') {
                return Err(RemoteError::StatusFailed(
                    "field values must not start with @".into(),
                ));
            }
            args.push("--field".to_string());
            args.push(format!("{key}={value}"));
        }

        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run_with_timeout(user_id, bin, &args, timeout).await
    }

    /// Apply a state change to a merge request and return the updated JSON.
    ///
    /// Merge requests can take a while for GitLab to actually merge (large
    /// repos, post-merge hooks, etc.), so the call gets a longer timeout.
    pub async fn gitlab_merge_request_action(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
        action: MergeRequestAction,
    ) -> Result<serde_json::Value, RemoteError> {
        if project_path.is_empty() || iid <= 0 {
            return Err(RemoteError::StatusFailed(
                "merge request reference is invalid".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let base = format!("projects/{encoded_project}/merge_requests/{iid}");

        let (path, fields): (String, Vec<(&str, &str)>) = match action {
            MergeRequestAction::Close => (base, vec![("state_event", "close")]),
            MergeRequestAction::Reopen => (base, vec![("state_event", "reopen")]),
            MergeRequestAction::Merge => (format!("{base}/merge"), Vec::new()),
            MergeRequestAction::MergeWhenPipelineSucceeds => (
                format!("{base}/merge"),
                vec![("merge_when_pipeline_succeeds", "true")],
            ),
        };

        let timeout = match action {
            MergeRequestAction::Merge => Duration::from_secs(120),
            _ => Duration::from_secs(30),
        };

        let output = self
            .gitlab_api_write(user_id, hostname, "PUT", &path, &fields, timeout)
            .await?;
        serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid merge request json: {e}"))
        })
    }

    fn api_host(hostname: &str) -> &str {
        if hostname.is_empty() {
            "gitlab.com"
        } else {
            hostname
        }
    }

    fn check_api_path(path: &str) -> Result<(), RemoteError> {
        if path.starts_with('/') {
            return Err(RemoteError::StatusFailed(
                "api path must not start with /".into(),
            ));
        }
        if !path.starts_with("projects/") {
            return Err(RemoteError::StatusFailed(
                "only project api paths are supported".into(),
            ));
        }
        if path.contains("..") || path.contains('\n') || path.contains('\r') {
            return Err(RemoteError::StatusFailed(
                "invalid characters in api path".into(),
            ));
        }
        Ok(())
    }

    /// Fetch the CI/CD pipelines for a GitLab merge request.
    ///
    /// [project_path] is the raw "group/project" style path and is encoded
    /// before being passed to `glab api`. The list is sorted with the most
    /// recently updated pipeline first.
    pub async fn gitlab_pipelines(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
    ) -> Result<Vec<GitLabPipeline>, RemoteError> {
        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/merge_requests/{iid}/pipelines?per_page=100"
        );

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let pipelines: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid pipeline json: {e}"))
        })?;

        let mut pipelines: Vec<GitLabPipeline> = pipelines
            .into_iter()
            .map(parse_pipeline)
            .collect::<Result<Vec<_>, _>>()?;
        pipelines.sort_by(|a, b| {
            let a_time = parse_timestamp(&a.updated_at);
            let b_time = parse_timestamp(&b.updated_at);
            b_time.cmp(&a_time)
        });
        Ok(pipelines)
    }

    /// Run a glab/gh command and return stdout, treating a non-zero exit as an
    /// error. Failures carry the combined output so the CLI's own message is
    /// reported; successes exclude stderr so JSON payloads stay parseable.
    async fn run(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
    ) -> Result<String, RemoteError> {
        self.run_with_timeout(user_id, bin, args, Duration::from_secs(30)).await
    }

    /// Run a glab/gh command with an explicit timeout and return stdout,
    /// treating a non-zero exit as an error.
    async fn run_with_timeout(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
        timeout_duration: Duration,
    ) -> Result<String, RemoteError> {
        let (stdout, stderr, success) =
            self.run_parts(user_id, bin, args, timeout_duration).await?;
        if !success {
            let combined = format!("{stdout}\n{stderr}");
            let msg = combined.trim();
            let msg = if msg.is_empty() { "command failed" } else { msg };
            return Err(RemoteError::StatusFailed(msg.to_string()));
        }
        Ok(stdout)
    }

    /// Run a glab/gh command and return the combined output plus success.
    async fn run_raw(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
    ) -> Result<(String, bool), RemoteError> {
        let (stdout, stderr, success) =
            self.run_parts(user_id, bin, args, Duration::from_secs(30)).await?;
        Ok((format!("{stdout}\n{stderr}"), success))
    }

    /// Run a glab/gh command and return stdout, stderr and success separately.
    async fn run_parts(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
        timeout_duration: Duration,
    ) -> Result<(String, String, bool), RemoteError> {
        let mut cmd = self.env_cmd(user_id, bin)?;
        cmd.args(args);

        let output = timeout(timeout_duration, cmd.output())
            .await
            .map_err(|_| RemoteError::Timeout)?
            .map_err(|e| RemoteError::StatusFailed(e.to_string()))?;

        Ok((
            String::from_utf8_lossy(&output.stdout).into_owned(),
            String::from_utf8_lossy(&output.stderr).into_owned(),
            output.status.success(),
        ))
    }

    fn env_cmd(&self, user_id: i64, bin: &Path) -> Result<Command, RemoteError> {
        let mut cmd = Command::new(bin);

        if self.isolated {
            let user_dir = self.config_root.join("glab").join(user_id.to_string());
            let xdg_config = user_dir.join(".config");
            std::fs::create_dir_all(&xdg_config)
                .map_err(|e| RemoteError::StatusFailed(format!("config dir failed: {e}")))?;

            cmd.current_dir(&user_dir)
                .env("HOME", &user_dir)
                .env("XDG_CONFIG_HOME", &xdg_config);
        } else {
            let cwd = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
            cmd.current_dir(cwd);
        }

        cmd.env("GLAB_CHECK_UPDATE", "false")
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

fn parse_timestamp(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(DateTime::UNIX_EPOCH)
}

fn parse_pipeline(value: serde_json::Value) -> Result<GitLabPipeline, RemoteError> {
    let status = value["status"]
        .as_str()
        .or_else(|| {
            value
                .get("detailed_status")
                .and_then(|v| v.get("group"))
                .and_then(|v| v.as_str())
        })
        .unwrap_or("unknown");

    let name = value["name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| value["ref"].as_str())
        .unwrap_or(status);

    let web_url = value["web_url"].as_str().unwrap_or("");
    let ref_name = value["ref"].as_str().unwrap_or("");
    let created_at = value["created_at"].as_str().unwrap_or("");
    let updated_at = value["updated_at"].as_str().unwrap_or("");

    Ok(GitLabPipeline {
        status: status.to_string(),
        name: name.to_string(),
        web_url: web_url.to_string(),
        ref_name: ref_name.to_string(),
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
    })
}
