//! Repository detection and status summary.

use std::path::{Path, PathBuf};
use std::time::Duration;

use super::{GitError, GitService};

/// Lightweight repository status for a project path.
#[derive(Debug, Clone)]
pub struct RepoStatus {
    pub is_repo: bool,
    pub toplevel: PathBuf,
    pub common_dir: PathBuf,
    pub branch: String,
    pub worktree_path: PathBuf,
    pub ahead: i64,
    pub behind: i64,
}

impl GitService {
    /// Return repository status for a project path. When `force` is true, skip
    /// the cache and re-detect the repository from the filesystem.
    pub async fn repo_status(&self, path: &Path, force: bool) -> Result<RepoStatus, GitError> {
        if self.git.is_none() {
            return Err(GitError::NotEnabled);
        }
        let key = path.to_string_lossy().to_string();
        if !force {
            if let Some(status) = self.repo_cache.get(&key) {
                return Ok(status);
            }
        }

        let status = self.detect_repo(path).await?;
        self.repo_cache.insert(key.clone(), status.clone());
        // Branch and worktree caches may be stale after a branch switch.
        self.branch_cache.invalidate(&key);
        self.worktree_cache.invalidate(&key);
        Ok(status)
    }

    /// Run `git status --porcelain=2 --branch` and `git diff HEAD --numstat`
    /// to produce a compact status summary. When `force` is true, re-detect
    /// the repository state before summarising.
    pub async fn status(&self, path: &Path, force: bool) -> Result<serde_json::Value, GitError> {
        self.repo_status(path, force).await?;

        let status_out = self
            .run_with(
                path,
                &["status", "--porcelain=2", "--branch"],
                Duration::from_secs(5),
            )
            .await?;
        let diff_out = self
            .run_with(path, &["diff", "HEAD", "--numstat"], Duration::from_secs(5))
            .await?;

        Ok(parse_status(&status_out, &diff_out))
    }

    async fn detect_repo(&self, path: &Path) -> Result<RepoStatus, GitError> {
        let worktree_path = tokio::fs::canonicalize(path)
            .await
            .unwrap_or_else(|_| path.to_path_buf());

        let top_out = match self
            .run_with(
                &worktree_path,
                &["rev-parse", "--show-toplevel"],
                Duration::from_secs(5),
            )
            .await
        {
            Ok(s) => s,
            Err(GitError::NotRepo) => {
                return Ok(RepoStatus {
                    is_repo: false,
                    toplevel: worktree_path.clone(),
                    common_dir: worktree_path.clone(),
                    branch: String::new(),
                    worktree_path,
                    ahead: 0,
                    behind: 0,
                });
            }
            Err(e) => return Err(e),
        };
        let top = PathBuf::from(top_out.trim());

        let common_out = self
            .run_with(
                &top,
                &["rev-parse", "--git-common-dir"],
                Duration::from_secs(5),
            )
            .await?;
        let common = top.join(common_out.trim());

        let branch = self
            .run_with(
                &top,
                &["symbolic-ref", "--short", "HEAD"],
                Duration::from_secs(5),
            )
            .await
            .map(|s| s.trim().to_string())
            .unwrap_or_default();

        let (ahead, behind) = self.tracking(&top, &branch).await.unwrap_or((0, 0));

        Ok(RepoStatus {
            is_repo: true,
            toplevel: top,
            common_dir: common,
            branch,
            worktree_path,
            ahead,
            behind,
        })
    }
}

/// Parse `git status --porcelain=2 --branch` and `git diff HEAD --numstat`
/// output into a compact JSON summary.
pub(super) fn parse_status(status_out: &str, diff_out: &str) -> serde_json::Value {
    let mut ahead = 0i64;
    let mut behind = 0i64;
    let mut dirty = 0usize;
    for line in status_out.lines() {
        if let Some(s) = line.strip_prefix("# branch.ab +") {
            let parts: Vec<&str> = s.split(' ').collect();
            if parts.len() == 2 {
                ahead = parts[0].parse().unwrap_or(0);
                behind = parts[1].parse().unwrap_or(0);
            }
        } else if !line.starts_with('#') && !line.is_empty() {
            dirty += 1;
        }
    }

    let mut changed = 0usize;
    let mut added = 0usize;
    let mut deleted = 0usize;
    for line in diff_out.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 {
            let a: usize = parts[0].parse().unwrap_or(0);
            let b: usize = parts[1].parse().unwrap_or(0);
            added += a;
            deleted += b;
            changed += 1;
        }
    }

    serde_json::json!({
        "ahead": ahead,
        "behind": behind,
        "dirty_files": dirty,
        "changed_files": changed,
        "insertions": added,
        "deletions": deleted,
    })
}

#[cfg(test)]
mod tests {
    use super::parse_status;

    #[test]
    fn parse_status_counts_dirty_and_diff() {
        let status = "# branch.ab +2 -0\n\
                      1 M. N... 100644 100644 100644 e69de29... e69de29... a.txt\n\
                      2 M. N... 100644 100644 100644 e69de29... e69de29... b.txt";
        let diff = "1\t2\tc.txt\n3\t4\td.txt";
        let out = parse_status(status, diff);
        assert_eq!(out["ahead"], 2);
        assert_eq!(out["behind"], 0);
        assert_eq!(out["dirty_files"], 2);
        assert_eq!(out["changed_files"], 2);
        assert_eq!(out["insertions"], 4);
        assert_eq!(out["deletions"], 6);
    }
}
