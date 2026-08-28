//! Low-level git command builder, execution, and tracking helpers.

use std::path::Path;
use std::time::Duration;

use regex::Regex;
use tokio::process::Command;
use tokio::time::timeout;

use super::{GitError, GitService};

/// Parse an upstream tracking string such as `[ahead 1, behind 2]` into
/// ahead/behind counts. Empty or missing tracking info becomes `(0, 0)`.
pub(super) fn parse_track(track: &str) -> (i64, i64) {
    let track = track.trim();
    if track.is_empty() {
        return (0, 0);
    }
    let ahead_re = Regex::new(r"ahead\s+(\d+)").expect("valid regex");
    let behind_re = Regex::new(r"behind\s+(\d+)").expect("valid regex");
    let ahead = ahead_re
        .captures(track)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .unwrap_or(0);
    let behind = behind_re
        .captures(track)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<i64>().ok())
        .unwrap_or(0);
    (ahead, behind)
}

impl GitService {
    pub(super) fn git_cmd(&self, cwd: &Path) -> Command {
        let mut cmd = Command::new(self.git.as_ref().expect("git enabled"));
        cmd.current_dir(cwd)
            .env("LC_ALL", "C")
            .env("GCM_INTERACTIVE", "never")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("SSH_ASKPASS_REQUIRE", "never");
        cmd
    }

    pub(super) async fn run(&self, cmd: &mut Command, max: Duration) -> Result<String, GitError> {
        match timeout(max, cmd.output()).await {
            Ok(Ok(out)) => {
                if out.status.success() {
                    Ok(String::from_utf8_lossy(&out.stdout).to_string())
                } else {
                    let msg = String::from_utf8_lossy(&out.stderr);
                    if msg.contains("not a git repository") {
                        Err(GitError::NotRepo)
                    } else {
                        Err(GitError::Other(msg.trim().to_string()))
                    }
                }
            }
            Ok(Err(e)) => Err(GitError::Other(e.to_string())),
            Err(_) => Err(GitError::Timeout),
        }
    }

    pub(super) async fn run_with(
        &self,
        cwd: &Path,
        args: &[&str],
        max: Duration,
    ) -> Result<String, GitError> {
        let mut cmd = self.git_cmd(cwd);
        cmd.args(args);
        self.run(&mut cmd, max).await
    }

    pub(super) async fn tracking(
        &self,
        path: &Path,
        branch: &str,
    ) -> Result<(i64, i64), GitError> {
        if branch.is_empty() || !super::branch::is_safe_branch_name(branch) {
            return Ok((0, 0));
        }

        // Read tracking state from the local upstream ref. This is fast and
        // avoids blocking the UI on a network fetch; the user can pull/fetch
        // explicitly to refresh remote state.
        let track = self
            .run_with(
                path,
                &[
                    "for-each-ref",
                    "--format=%(upstream:track)",
                    &format!("refs/heads/{}", branch),
                ],
                Duration::from_secs(5),
            )
            .await
            .unwrap_or_default();

        Ok(parse_track(&track))
    }
}

#[cfg(test)]
mod tests {
    use super::parse_track;

    #[test]
    fn parse_track_extracts_ahead_and_behind() {
        assert_eq!(parse_track("[ahead 3, behind 2]"), (3, 2));
        assert_eq!(parse_track("[ahead 1]"), (1, 0));
        assert_eq!(parse_track("[behind 5]"), (0, 5));
        assert_eq!(parse_track(""), (0, 0));
    }
}
