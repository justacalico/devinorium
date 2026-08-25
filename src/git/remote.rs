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
use tokio::time::{sleep, timeout};

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

/// A GitLab project resolved from a git remote URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLabProjectRef {
    pub hostname: String,
    pub project_path: String,
}

/// A lightweight merge request summary, used to surface the open MR linked
/// to a thread's branch without loading the full diff/comment payload.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabMergeRequestSummary {
    pub iid: i64,
    pub title: String,
    pub state: String,
    pub source_branch: String,
    pub target_branch: String,
    pub web_url: String,
    pub draft: bool,
}

/// Parse a git remote URL into a GitLab host and project path.
///
/// Handles the common forms:
///   git@gitlab.com:group/project.git
///   git@gitlab.example.com:group/subgroup/project.git
///   ssh://git@gitlab.com:22/group/project.git
///   https://gitlab.com/group/subgroup/project.git
///   https://user:token@gitlab.com/group/project.git
///
/// Returns `None` for URLs that are not parseable as a GitLab remote.
pub fn parse_gitlab_remote_url(url: &str) -> Option<GitLabProjectRef> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }

    // ssh://[user@]host[:port]/path
    if let Some(rest) = url.strip_prefix("ssh://") {
        let after_user = match rest.split_once('@') {
            Some((_, host_and_path)) => host_and_path,
            None => rest,
        };
        let (host_and_port, path) = after_user.split_once('/')?;
        let hostname = host_and_port.split_once(':').map(|(h, _)| h).unwrap_or(host_and_port);
        return build_ref(hostname, path);
    }

    // git@host:path  (scp-style)
    if let Some(rest) = url.strip_prefix("git@") {
        let (host, path) = rest.split_once(':')?;
        return build_ref(host, path);
    }

    // http(s)://[user:pass@]host/path
    if let Some(rest) = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://")) {
        let after_auth = match rest.split_once('@') {
            Some((_, host_and_path)) => host_and_path,
            None => rest,
        };
        let (host, path) = after_auth.split_once('/')?;
        // Strip a trailing query/fragment if present.
        let path = path.split(['?', '#']).next().unwrap_or(path);
        return build_ref(host, path);
    }

    None
}

fn build_ref(hostname: &str, path: &str) -> Option<GitLabProjectRef> {
    let hostname = hostname.trim();
    let mut project_path = path.trim().trim_end_matches(".git").to_string();
    // A trailing slash is meaningless and breaks API paths.
    while project_path.ends_with('/') {
        project_path.pop();
    }
    if hostname.is_empty() || project_path.is_empty() {
        return None;
    }
    // Reject paths that look like filesystem traversal or contain whitespace
    // or control characters that could break the API path or shell handoff.
    if project_path.contains(' ')
        || project_path.contains("..")
        || project_path.contains('\0')
        || project_path.contains('\n')
        || project_path.contains('\r')
    {
        return None;
    }
    Some(GitLabProjectRef {
        hostname: hostname.to_string(),
        project_path,
    })
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
    /// How long to wait for GitLab to finish a synchronous `merge` call before
    /// falling back to polling the merge request state.
    merge_timeout: Duration,
    /// How long to wait between merge request state polls.
    poll_interval: Duration,
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
    /// `Merge` can take a while for GitLab to actually complete (large repos,
    /// post-merge hooks, etc.). If the first call times out we poll the MR
    /// state so the user sees the final result instead of a raw timeout.
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
            MergeRequestAction::Close => (base.clone(), vec![("state_event", "close")]),
            MergeRequestAction::Reopen => (base.clone(), vec![("state_event", "reopen")]),
            MergeRequestAction::Merge => (format!("{base}/merge"), Vec::new()),
            MergeRequestAction::MergeWhenPipelineSucceeds => (
                format!("{base}/merge"),
                vec![("merge_when_pipeline_succeeds", "true")],
            ),
        };

        let timeout = match action {
            MergeRequestAction::Merge => self.merge_timeout,
            _ => Duration::from_secs(30),
        };

        match self
            .gitlab_api_write(user_id, hostname, "PUT", &path, &fields, timeout)
            .await
        {
            Ok(output) => Self::parse_merge_request_json(&output),
            Err(RemoteError::Timeout) if action == MergeRequestAction::Merge => {
                self.poll_merge_request_state(user_id, hostname, &base).await
            }
            Err(e) => Err(e),
        }
    }

    async fn poll_merge_request_state(
        &self,
        user_id: i64,
        hostname: &str,
        mr_path: &str,
    ) -> Result<serde_json::Value, RemoteError> {
        let max_attempts = 60; // up to 60 * 3s = 3 minutes with defaults

        for attempt in 0..max_attempts {
            sleep(self.poll_interval).await;
            match self.gitlab_api(user_id, hostname, mr_path).await {
                Ok(output) => {
                    let value = Self::parse_merge_request_json(&output)?;
                    if let Some(state) = value["state"].as_str() {
                        if state == "merged" || state == "closed" {
                            return Ok(value);
                        }
                    }
                    // Still open or in an intermediate state; keep polling.
                }
                Err(RemoteError::Timeout) if attempt == max_attempts - 1 => {
                    return Err(RemoteError::StatusFailed(
                        "GitLab did not finish the merge in time".into(),
                    ));
                }
                Err(RemoteError::Timeout) => continue,
                Err(e) => return Err(e),
            }
        }

        Err(RemoteError::StatusFailed(
            "GitLab did not finish the merge in time".into(),
        ))
    }

    fn parse_merge_request_json(output: &str) -> Result<serde_json::Value, RemoteError> {
        serde_json::from_str(output).map_err(|e| {
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

    /// Find the open merge request whose source branch matches [branch] in the
    /// given GitLab project. Returns the first match, or `None` if there is no
    /// open merge request for that branch.
    pub async fn gitlab_merge_request_for_branch(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        branch: &str,
    ) -> Result<Option<GitLabMergeRequestSummary>, RemoteError> {
        if project_path.is_empty() || branch.is_empty() {
            return Err(RemoteError::StatusFailed(
                "project and branch are required".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let encoded_branch = utf8_percent_encode(branch, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/merge_requests\
             ?source_branch={encoded_branch}&state=opened&per_page=1"
        );

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid merge request json: {e}"))
        })?;

        Ok(list.into_iter().next().map(parse_merge_request_summary))
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
    ///
    /// Retries on `ETXTBSY` because freshly written shell scripts can briefly
    /// appear busy if a sibling thread forked while the file was open for
    /// writing.
    async fn run_parts(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
        timeout_duration: Duration,
    ) -> Result<(String, String, bool), RemoteError> {
        const MAX_ATTEMPTS: usize = 5;
        const BACKOFF: Duration = Duration::from_millis(25);

        for attempt in 0..MAX_ATTEMPTS {
            let mut cmd = self.env_cmd(user_id, bin)?;
            cmd.args(args);

            let output = match timeout(timeout_duration, cmd.output()).await {
                Ok(output) => output,
                Err(_) => return Err(RemoteError::Timeout),
            };

            match output {
                Ok(output) => {
                    return Ok((
                        String::from_utf8_lossy(&output.stdout).into_owned(),
                        String::from_utf8_lossy(&output.stderr).into_owned(),
                        output.status.success(),
                    ));
                }
                Err(e)
                    if e.kind() == std::io::ErrorKind::ExecutableFileBusy
                        && attempt + 1 < MAX_ATTEMPTS =>
                {
                    sleep(BACKOFF).await;
                }
                Err(e) => return Err(RemoteError::StatusFailed(e.to_string())),
            }
        }

        unreachable!()
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

fn parse_merge_request_summary(value: serde_json::Value) -> GitLabMergeRequestSummary {
    let iid = value["iid"]
        .as_i64()
        .or_else(|| value["iid"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);
    GitLabMergeRequestSummary {
        iid,
        title: value["title"].as_str().unwrap_or("").to_string(),
        state: value["state"].as_str().unwrap_or("").to_string(),
        source_branch: value["source_branch"].as_str().unwrap_or("").to_string(),
        target_branch: value["target_branch"].as_str().unwrap_or("").to_string(),
        web_url: value["web_url"].as_str().unwrap_or("").to_string(),
        draft: value["draft"].as_bool().unwrap_or(false),
    }
}
