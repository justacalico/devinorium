//! GitLab authentication and status parsing.

use regex::Regex;

use super::{GitRemoteService, RemoteError};

/// Parsed `glab auth status` for a single host.
#[derive(Debug, Clone)]
pub struct GitLabStatus {
    pub host: String,
    pub authed: bool,
    pub account: Option<String>,
}

impl GitRemoteService {
    /// Verify that `glab` is already authenticated for the given host.
    ///
    /// The user must authenticate via the glab CLI itself
    /// (`glab auth login`); this method only reports the current status.
    pub async fn login_gitlab(
        &self,
        user_id: i64,
        hostname: Option<&str>,
    ) -> Result<GitLabStatus, RemoteError> {
        self.glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
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
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
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
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self.run_raw(user_id, bin, &["auth", "status"]).await?;
        Self::parse_gitlab_status(&output)
    }

    /// Return the stored token for the given GitLab host, if one exists.
    ///
    /// The token is read from `glab`'s own config, so Devinorium never stores
    /// credentials itself. Returns `None` when `glab` is not installed or has
    /// no token for the host.
    pub async fn gitlab_token_for_host(
        &self,
        user_id: i64,
        hostname: &str,
    ) -> Result<Option<String>, RemoteError> {
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
        let host = Self::api_host(hostname);
        let (output, success) = self
            .run_raw(user_id, bin, &["config", "get", "token", "--host", host])
            .await?;
        if !success || output.trim().is_empty() {
            return Ok(None);
        }
        Ok(Some(output.trim().to_string()))
    }

    pub(super) async fn gitlab_status_for_host(
        &self,
        user_id: i64,
        host: &str,
    ) -> Result<GitLabStatus, RemoteError> {
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self
            .run_raw(user_id, bin, &["auth", "status", "--hostname", host])
            .await?;
        Self::parse_gitlab_status(&output)
    }

    pub(super) fn parse_gitlab_status(output: &str) -> Result<GitLabStatus, RemoteError> {
        static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let re = RE.get_or_init(|| {
            Regex::new(r"(?:[✓✗xX!]\s+)?Logged in to\s+(\S+)\s+as\s+(\S+)").unwrap()
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_gitlab_status_extracts_logged_in_user() {
        let out = "gitlab.com\n  Logged in to gitlab.com as testuser";
        let s = GitRemoteService::parse_gitlab_status(out).unwrap();
        assert_eq!(s.host, "gitlab.com");
        assert!(s.authed);
        assert_eq!(s.account.as_deref(), Some("testuser"));
    }

    #[test]
    fn parse_gitlab_status_falls_back_to_host_when_not_authed() {
        let out = "gitlab.example.com\n  ! No token found";
        let s = GitRemoteService::parse_gitlab_status(out).unwrap();
        assert_eq!(s.host, "gitlab.example.com");
        assert!(!s.authed);
        assert!(s.account.is_none());
    }

    #[test]
    fn parse_gitlab_status_rejects_garbage() {
        assert!(GitRemoteService::parse_gitlab_status("garbage output").is_err());
        assert!(GitRemoteService::parse_gitlab_status("ERROR: no token").is_err());
        assert!(GitRemoteService::parse_gitlab_status("").is_err());
    }
}
