//! Push, pull, and remote URL helpers.

use std::path::Path;
use std::time::Duration;

use super::branch::is_safe_branch_name;
use super::{GitError, GitService};

impl GitService {
    /// Fetch from the current branch's tracked remote to refresh
    /// remote-tracking refs. This is a best-effort refresh used after branch
    /// switches so the UI can re-check for pull.
    pub async fn fetch(&self, path: &Path) -> Result<(), GitError> {
        self.repo_status(path, false).await?;
        let mut cmd = self.git_cmd(path);
        cmd.arg("fetch");
        self.run(&mut cmd, Duration::from_secs(30)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Pull the current branch's upstream using fast-forward only.
    pub async fn pull(&self, path: &Path) -> Result<(), GitError> {
        self.repo_status(path, false).await?;
        let mut cmd = self.git_cmd(path);
        cmd.arg("pull").arg("--ff-only");
        self.run(&mut cmd, Duration::from_secs(60)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Pull a specific branch's tracked remote, fast-forwarding the local ref.
    pub async fn pull_branch(&self, path: &Path, name: &str) -> Result<(), GitError> {
        self.repo_status(path, false).await?;

        let name = name.trim();
        if name.is_empty() {
            return Err(GitError::Other("branch name is required".to_string()));
        }
        if !is_safe_branch_name(name) {
            return Err(GitError::Other("invalid branch name".to_string()));
        }

        let current = self
            .run_with(
                path,
                &["rev-parse", "--abbrev-ref", "HEAD"],
                Duration::from_secs(5),
            )
            .await
            .unwrap_or_default()
            .trim()
            .to_string();

        if name == current {
            return self.pull(path).await;
        }

        let full_upstream = self
            .run_with(
                path,
                &[
                    "for-each-ref",
                    "--format=%(upstream)",
                    &format!("refs/heads/{name}"),
                ],
                Duration::from_secs(5),
            )
            .await?
            .trim()
            .to_string();

        if full_upstream.is_empty() {
            return Err(GitError::Other("branch has no upstream".to_string()));
        }

        let remote = self
            .run_with(
                path,
                &["config", "--get", &format!("branch.{name}.remote")],
                Duration::from_secs(5),
            )
            .await?
            .trim()
            .to_string();

        if !is_safe_branch_name(&remote) {
            return Err(GitError::Other("invalid remote name".to_string()));
        }

        let prefix = format!("refs/remotes/{remote}/");
        let remote_branch = full_upstream
            .strip_prefix(&prefix)
            .ok_or_else(|| GitError::Other("invalid upstream".to_string()))?;

        if !is_safe_branch_name(remote_branch) {
            return Err(GitError::Other("invalid remote branch".to_string()));
        }

        let mut cmd = self.git_cmd(path);
        cmd.arg("fetch")
            .arg(&remote)
            .arg(format!("refs/heads/{remote_branch}:refs/heads/{name}"));
        self.run(&mut cmd, Duration::from_secs(60)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Push the current branch to its remote, setting upstream if needed.
    pub async fn push(&self, path: &Path) -> Result<(), GitError> {
        let status = self.repo_status(path, true).await?;
        if status.branch.is_empty() || !is_safe_branch_name(&status.branch) {
            return Err(GitError::Other(
                "cannot push without a current branch".to_string(),
            ));
        }

        let tracked_remote = self
            .run_with(
                path,
                &["config", &format!("branch.{}.remote", status.branch)],
                Duration::from_secs(5),
            )
            .await
            .map(|s| s.trim().to_string())
            .ok()
            .filter(|s| !s.is_empty());

        let remotes = self
            .run_with(path, &["remote"], Duration::from_secs(5))
            .await?;

        let remote = pick_remote(tracked_remote.as_deref(), &remotes)
            .ok_or_else(|| GitError::Other("no remote configured".to_string()))?;

        let mut cmd = self.git_cmd(path);
        cmd.arg("push").arg("-u").arg(remote).arg(&status.branch);
        self.run(&mut cmd, Duration::from_secs(60)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Return the fetch URL of the branch's tracked remote, falling back to
    /// `origin` and then the first listed remote.
    pub async fn remote_url(&self, path: &Path) -> Result<String, GitError> {
        let status = self.repo_status(path, false).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }

        let tracked_remote = if !status.branch.is_empty() && is_safe_branch_name(&status.branch) {
            self.run_with(
                path,
                &["config", &format!("branch.{}.remote", status.branch)],
                Duration::from_secs(5),
            )
            .await
            .map(|s| s.trim().to_string())
            .ok()
            .filter(|s| !s.is_empty())
        } else {
            None
        };

        let remotes = self
            .run_with(path, &["remote"], Duration::from_secs(5))
            .await?;

        let remote = pick_remote(tracked_remote.as_deref(), &remotes)
            .ok_or_else(|| GitError::Other("no remote configured".to_string()))?;

        let url = self
            .run_with(
                path,
                &["remote", "get-url", &remote],
                Duration::from_secs(5),
            )
            .await?;
        Ok(url.trim().to_string())
    }
}

/// Pick a remote name from an optional tracked remote and the output of
/// `git remote`.
pub(super) fn pick_remote(tracked: Option<&str>, remotes: &str) -> Option<String> {
    if let Some(r) = tracked {
        if !r.is_empty() {
            return Some(r.to_string());
        }
    }
    let lines: Vec<&str> = remotes.lines().collect();
    if lines.is_empty() {
        return None;
    }
    lines
        .iter()
        .find(|&&r| r == "origin")
        .copied()
        .or(lines.first().copied())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::pick_remote;

    #[test]
    fn pick_remote_prefers_tracked_then_origin_then_first() {
        assert_eq!(
            pick_remote(Some("upstream"), "origin\nupstream"),
            Some("upstream".to_string())
        );
        assert_eq!(
            pick_remote(None, "origin\nupstream"),
            Some("origin".to_string())
        );
        assert_eq!(
            pick_remote(None, "upstream\nfork"),
            Some("upstream".to_string())
        );
        assert_eq!(pick_remote(None, ""), None);
    }
}
