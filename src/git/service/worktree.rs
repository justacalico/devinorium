//! Worktree listing and manipulation.

use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{GitError, GitService};
use super::branch::is_safe_branch_name;

/// A worktree.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Worktree {
    pub path: PathBuf,
    pub head: String,
    pub branch: Option<String>,
    pub is_main: bool,
}

/// Worktree names are used as filesystem directory names, so we disallow
/// path separators entirely to prevent traversal.
pub(super) fn is_safe_worktree_name(name: &str) -> bool {
    if !is_safe_branch_name(name) {
        return false;
    }
    if name.contains('/') || name.contains('\\') {
        return false;
    }
    true
}

impl GitService {
    /// Return worktrees. When `force` is true, re-list worktrees from git.
    pub async fn worktrees(&self, path: &Path, force: bool) -> Result<Vec<Worktree>, GitError> {
        let status = self.repo_status(path, force).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let key = path.to_string_lossy().to_string();
        if force {
            self.worktree_cache.invalidate(&key);
        }
        if let Some(worktrees) = self.worktree_cache.get(&key) {
            return Ok(worktrees);
        }
        let worktrees = self.list_worktrees(path).await?;
        self.worktree_cache.insert(key, worktrees.clone());
        Ok(worktrees)
    }

    /// Create a worktree, optionally creating a new branch.
    pub async fn create_worktree(
        &self,
        path: &Path,
        name: &str,
        base: &str,
        new_branch: bool,
    ) -> Result<Worktree, GitError> {
        self.repo_status(path, false).await?;

        if !is_safe_worktree_name(name) {
            return Err(GitError::Other("invalid worktree name".to_string()));
        }
        if base.trim().is_empty() {
            return Err(GitError::Other("base branch is required".to_string()));
        }

        let worktree_path = path.join(name);
        match tokio::fs::try_exists(&worktree_path).await {
            Ok(true) => return Err(GitError::Other("worktree path already exists".to_string())),
            Ok(false) => {}
            Err(e) => return Err(GitError::Other(format!("filesystem error: {e}"))),
        }

        let mut cmd = self.git_cmd(path);
        cmd.arg("worktree").arg("add");
        if new_branch {
            cmd.arg("-b").arg(name);
        }
        cmd.arg(&worktree_path).arg(base);
        self.run(&mut cmd, Duration::from_secs(15)).await?;

        self.invalidate(path);

        // Resolve the actual worktree.
        let worktrees = self.list_worktrees(path).await?;
        worktrees
            .into_iter()
            .find(|w| w.path == worktree_path)
            .ok_or_else(|| GitError::Other("failed to resolve new worktree".to_string()))
    }

    /// Remove a worktree at `worktree_path`.
    pub async fn remove_worktree(&self, path: &Path, worktree_path: &Path) -> Result<(), GitError> {
        self.repo_status(path, false).await?;

        let worktrees = self.list_worktrees(path).await?;
        let target = worktrees
            .into_iter()
            .find(|w| w.path == worktree_path)
            .ok_or_else(|| GitError::Other("worktree not found".to_string()))?;
        if target.is_main {
            return Err(GitError::Other(
                "cannot remove the main worktree".to_string(),
            ));
        }

        let mut cmd = self.git_cmd(path);
        cmd.arg("worktree")
            .arg("remove")
            .arg("--force")
            .arg(worktree_path);
        self.run(&mut cmd, Duration::from_secs(15)).await?;

        self.invalidate(path);
        Ok(())
    }

    async fn list_worktrees(&self, path: &Path) -> Result<Vec<Worktree>, GitError> {
        let out = self
            .run_with(
                path,
                &["worktree", "list", "--porcelain", "-z"],
                Duration::from_secs(5),
            )
            .await?;
        Ok(parse_worktrees(&out))
    }
}

/// Parse `git worktree list --porcelain -z` output.
pub(super) fn parse_worktrees(output: &str) -> Vec<Worktree> {
    let mut worktrees = Vec::new();
    let mut path_buf = None;
    let mut head = String::new();
    let mut branch = None;

    for token in output.split('\0') {
        if token.is_empty() {
            continue;
        }
        if token.starts_with("worktree ") {
            if let Some(p) = path_buf.take() {
                // The first worktree listed by `git worktree list` is always
                // the main (original) worktree.
                let is_main = worktrees.is_empty();
                worktrees.push(Worktree {
                    path: p,
                    head: head.clone(),
                    branch: branch.clone(),
                    is_main,
                });
            }
            path_buf = Some(PathBuf::from(token.split_at(9).1));
            head.clear();
            branch = None;
        } else if token.starts_with("HEAD ") {
            head = token.split_at(5).1.to_string();
        } else if token.starts_with("branch ") {
            branch = Some(token.split_at(7).1.to_string());
        }
    }

    if let Some(p) = path_buf {
        let is_main = worktrees.is_empty();
        worktrees.push(Worktree {
            path: p,
            head,
            branch,
            is_main,
        });
    }

    worktrees
}

#[cfg(test)]
mod tests {
    use super::{is_safe_worktree_name, parse_worktrees};

    #[test]
    fn is_safe_worktree_name_rejects_path_separators() {
        assert!(is_safe_worktree_name("feature"));
        assert!(!is_safe_worktree_name("foo/bar"));
        assert!(!is_safe_worktree_name("foo\\bar"));
        assert!(!is_safe_worktree_name("../escape"));
    }

    #[test]
    fn parse_worktrees_lists_main_first() {
        let out = "worktree /repo\0HEAD abc123\0branch refs/heads/main\0worktree /repo.wt\0HEAD def456\0";
        let worktrees = parse_worktrees(out);
        assert_eq!(worktrees.len(), 2);
        assert_eq!(worktrees[0].path, std::path::PathBuf::from("/repo"));
        assert!(worktrees[0].is_main);
        assert_eq!(worktrees[0].branch.as_deref(), Some("refs/heads/main"));
        assert_eq!(worktrees[1].path, std::path::PathBuf::from("/repo.wt"));
        assert!(!worktrees[1].is_main);
    }
}
