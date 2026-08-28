//! Low-level `glab` CLI invocation and API proxying.

use std::path::Path;
use std::time::Duration;

use tokio::process::Command;
use tokio::time::{sleep, timeout};

use super::{GitRemoteService, RemoteError};

impl GitRemoteService {
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
    pub(super) async fn gitlab_api_write(
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

    /// Run a glab/gh command and return stdout, treating a non-zero exit as an
    /// error. Failures carry the combined output so the CLI's own message is
    /// reported; successes exclude stderr so JSON payloads stay parseable.
    pub(super) async fn run(
        &self,
        user_id: i64,
        bin: &Path,
        args: &[&str],
    ) -> Result<String, RemoteError> {
        self.run_with_timeout(user_id, bin, args, Duration::from_secs(30))
            .await
    }

    /// Run a glab/gh command with an explicit timeout and return stdout,
    /// treating a non-zero exit as an error.
    pub(super) async fn run_with_timeout(
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
    pub(super) async fn run_raw(
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
    pub(super) async fn run_parts(
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

    pub(super) fn env_cmd(&self, user_id: i64, bin: &Path) -> Result<Command, RemoteError> {
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[tokio::test]
    async fn gitlab_api_write_rejects_at_file_fields() {
        let svc = GitRemoteService::with_glab_bin(
            "/tmp",
            Some(PathBuf::from("/nonexistent-glab")),
        );
        let err = svc
            .gitlab_api_write(
                1,
                "gitlab.com",
                "PUT",
                "projects/foo/merge_requests/1",
                &[("note", "@/etc/passwd")],
                Duration::from_secs(1),
            )
            .await
            .unwrap_err();
        assert!(matches!(
            err,
            RemoteError::StatusFailed(ref msg) if msg.contains("@")
        ));
    }
}
