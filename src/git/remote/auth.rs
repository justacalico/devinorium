//! Git host authentication and status parsing for `glab` and `gh`.

use regex::Regex;

use super::{CliKind, GitRemoteService, RemoteError};

/// Parsed `glab auth status`/`gh auth status` for a single host.
#[derive(Debug, Clone)]
pub struct GitHostStatus {
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
    ) -> Result<GitHostStatus, RemoteError> {
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
            .run(
                user_id,
                CliKind::Glab,
                bin,
                &["auth", "logout", "--hostname", host],
            )
            .await;
        let _ = self
            .run(
                user_id,
                CliKind::Glab,
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
    pub async fn gitlab_status(&self, user_id: i64) -> Result<GitHostStatus, RemoteError> {
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self
            .run_raw(user_id, CliKind::Glab, bin, &["auth", "status"])
            .await?;
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
        let host = Self::api_host(super::GitHost::GitLab, hostname);
        let (output, success) = self
            .run_raw(
                user_id,
                CliKind::Glab,
                bin,
                &["config", "get", "token", "--host", host],
            )
            .await?;
        if !success || output.trim().is_empty() {
            return Ok(None);
        }
        Ok(Some(output.trim().to_string()))
    }

    /// Verify that `gh` is already authenticated for the given host.
    ///
    /// The user must authenticate via the gh CLI itself
    /// (`gh auth login`); this method only reports the current status.
    pub async fn login_github(
        &self,
        user_id: i64,
        hostname: Option<&str>,
    ) -> Result<GitHostStatus, RemoteError> {
        self.gh_bin
            .as_ref()
            .ok_or(RemoteError::GitHubNotAvailable)?;
        let host = hostname.unwrap_or("github.com");

        let status = self.github_status_for_host(user_id, host).await?;
        if status.authed {
            Ok(status)
        } else {
            Err(RemoteError::LoginFailed(
                "gh is not authenticated for this host; run `gh auth login`".into(),
            ))
        }
    }

    /// Log out of a GitHub host.
    pub async fn logout_github(
        &self,
        user_id: i64,
        hostname: Option<&str>,
    ) -> Result<(), RemoteError> {
        let bin = self
            .gh_bin
            .as_ref()
            .ok_or(RemoteError::GitHubNotAvailable)?;
        let host = hostname.unwrap_or("github.com");

        let _ = self
            .run(
                user_id,
                CliKind::Gh,
                bin,
                &["auth", "logout", "--hostname", host],
            )
            .await;

        // Verify the logout took effect.
        let after = self.github_status_for_host(user_id, host).await?;
        if after.authed {
            return Err(RemoteError::LogoutFailed(format!(
                "still logged in as {}",
                after.account.unwrap_or_default()
            )));
        }
        Ok(())
    }

    /// Return the first available GitHub status. Used for the connections list.
    pub async fn github_status(&self, user_id: i64) -> Result<GitHostStatus, RemoteError> {
        let bin = self
            .gh_bin
            .as_ref()
            .ok_or(RemoteError::GitHubNotAvailable)?;
        let (output, _) = self
            .run_raw(user_id, CliKind::Gh, bin, &["auth", "status"])
            .await?;
        Self::parse_github_status(&output, "github.com")
    }

    /// Return the stored token for the given GitHub host, if one exists.
    ///
    /// The token is read from `gh`'s own config, so Devinorium never stores
    /// credentials itself. Returns `None` when `gh` is not installed or has
    /// no token for the host.
    pub async fn github_token_for_host(
        &self,
        user_id: i64,
        hostname: &str,
    ) -> Result<Option<String>, RemoteError> {
        let bin = self
            .gh_bin
            .as_ref()
            .ok_or(RemoteError::GitHubNotAvailable)?;
        let host = Self::api_host(super::GitHost::GitHub, hostname);
        let (output, success) = self
            .run_raw(
                user_id,
                CliKind::Gh,
                bin,
                &["auth", "token", "--hostname", host],
            )
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
    ) -> Result<GitHostStatus, RemoteError> {
        let bin = self
            .glab_bin
            .as_ref()
            .ok_or(RemoteError::GitLabNotAvailable)?;
        let (output, _) = self
            .run_raw(
                user_id,
                CliKind::Glab,
                bin,
                &["auth", "status", "--hostname", host],
            )
            .await?;
        Self::parse_gitlab_status(&output)
    }

    pub(super) async fn github_status_for_host(
        &self,
        user_id: i64,
        host: &str,
    ) -> Result<GitHostStatus, RemoteError> {
        let bin = self
            .gh_bin
            .as_ref()
            .ok_or(RemoteError::GitHubNotAvailable)?;
        let (output, _) = self
            .run_raw(
                user_id,
                CliKind::Gh,
                bin,
                &["auth", "status", "--hostname", host],
            )
            .await?;
        Self::parse_github_status(&output, host)
    }

    pub(super) fn parse_gitlab_status(output: &str) -> Result<GitHostStatus, RemoteError> {
        static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let re = RE.get_or_init(|| {
            Regex::new(r"(?:[✓✗xX!]\s+)?Logged in to\s+(\S+)\s+as\s+(\S+)").unwrap()
        });

        if let Some(caps) = re.captures(output) {
            return Ok(GitHostStatus {
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
            return Ok(GitHostStatus {
                host: line.to_string(),
                authed: false,
                account: None,
            });
        }

        Err(RemoteError::StatusFailed(
            "could not parse glab auth status output".into(),
        ))
    }

    /// Parse `gh auth status` output for the requested host.
    ///
    /// `gh` prints one section per configured host:
    ///
    /// ```text
    /// github.com
    ///   ✓ Logged in to github.com account octocat (~/gh/hosts.yml)
    ///   - Active account: true
    ///   - Token: ***
    /// ```
    ///
    /// Older versions wrote `as` instead of `account`. When several accounts
    /// share a host, the one marked `Active account: true` wins. A host
    /// section without a login line means `gh` knows the host but has no
    /// token for it.
    pub(super) fn parse_github_status(
        output: &str,
        fallback_host: &str,
    ) -> Result<GitHostStatus, RemoteError> {
        static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let re = RE
            .get_or_init(|| Regex::new(r"Logged in to\s+(\S+)\s+(?:account|as)\s+(\S+)").unwrap());

        let matches: Vec<_> = re.captures_iter(output).collect();
        if !matches.is_empty() {
            let chosen = matches
                .iter()
                .find(|m| {
                    let end = m.get(0).unwrap().end();
                    let after = &output[end..];
                    let block = after
                        .find("Logged in to")
                        .map(|i| &after[..i])
                        .unwrap_or(after);
                    block.contains("Active account: true")
                })
                .unwrap_or(&matches[0]);
            return Ok(GitHostStatus {
                host: chosen[1].to_string(),
                authed: true,
                account: Some(chosen[2].to_string()),
            });
        }

        // A host section header is a bare hostname line; seeing one means gh
        // knows the host but has no credentials for it.
        for line in output.lines().map(str::trim) {
            if line.is_empty()
                || line.starts_with('✓')
                || line.starts_with('✗')
                || line.starts_with('x')
                || line.starts_with('X')
                || line.starts_with('!')
                || line.starts_with("- ")
            {
                continue;
            }
            if line.contains(' ') {
                continue;
            }
            return Ok(GitHostStatus {
                host: line.to_string(),
                authed: false,
                account: None,
            });
        }

        // `gh auth status` with no credentials at all prints a sentence
        // rather than a host section; an unknown `--hostname` produces a
        // "not found" message instead.
        let lower = output.to_lowercase();
        if lower.contains("not logged")
            || lower.contains("no github hosts")
            || lower.contains("not found")
        {
            return Ok(GitHostStatus {
                host: fallback_host.to_string(),
                authed: false,
                account: None,
            });
        }

        Err(RemoteError::StatusFailed(
            "could not parse gh auth status output".into(),
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

    #[test]
    fn parse_github_status_extracts_logged_in_account() {
        let out = "github.com\n  ✓ Logged in to github.com account octocat (~/gh/hosts.yml)\n  - Active account: true\n  - Token: ***";
        let s = GitRemoteService::parse_github_status(out, "github.com").unwrap();
        assert_eq!(s.host, "github.com");
        assert!(s.authed);
        assert_eq!(s.account.as_deref(), Some("octocat"));
    }

    #[test]
    fn parse_github_status_accepts_older_as_format() {
        let out = "github.com\n  ✓ Logged in to github.com as octocat";
        let s = GitRemoteService::parse_github_status(out, "github.com").unwrap();
        assert_eq!(s.account.as_deref(), Some("octocat"));
    }

    #[test]
    fn parse_github_status_prefers_active_account() {
        let out = "github.com\n  \
            ✓ Logged in to github.com account first (~/gh/hosts.yml)\n  \
            - Active account: false\n  \
            ✓ Logged in to github.com account second (~/gh/hosts.yml)\n  \
            - Active account: true\n";
        let s = GitRemoteService::parse_github_status(out, "github.com").unwrap();
        assert_eq!(s.account.as_deref(), Some("second"));
    }

    #[test]
    fn parse_github_status_reports_not_logged_in() {
        let out = "github.com\n  ✗ Not logged in to github.com";
        let s = GitRemoteService::parse_github_status(out, "github.com").unwrap();
        assert_eq!(s.host, "github.com");
        assert!(!s.authed);
    }

    #[test]
    fn parse_github_status_uses_fallback_for_no_hosts_message() {
        let out =
            "You are not logged into any GitHub hosts. Run \"gh auth login\" to authenticate.";
        let s = GitRemoteService::parse_github_status(out, "github.com").unwrap();
        assert_eq!(s.host, "github.com");
        assert!(!s.authed);
    }

    #[test]
    fn parse_github_status_rejects_garbage() {
        assert!(GitRemoteService::parse_github_status("", "github.com").is_err());
        assert!(GitRemoteService::parse_github_status("!!!", "github.com").is_err());
    }
}
