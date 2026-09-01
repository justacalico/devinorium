//! Repository detection and status summary.

use std::collections::HashMap;
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

    /// Return a map of immediate entry names in `path` to a Git status label.
    ///
    /// Labels mirror the common VCS file states: `untracked`, `modified`,
    /// `added`, `deleted`, `renamed`, `copied`, `conflict`, `ignored`, and
    /// `descendant` (for directories that contain changed files).
    pub async fn file_statuses(&self, path: &Path) -> Result<HashMap<String, String>, GitError> {
        if self.git.is_none() {
            return Err(GitError::NotEnabled);
        }

        let repo = self.repo_status(path, true).await?;
        if !repo.is_repo {
            return Ok(HashMap::new());
        }

        let out = self
            .run_with(
                path,
                &[
                    "-c",
                    "status.renames=copies",
                    "status",
                    "--porcelain=1",
                    "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                    "--renames",
                    "--",
                    ".",
                ],
                Duration::from_secs(5),
            )
            .await?;

        let target_rel = path
            .strip_prefix(&repo.toplevel)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();

        Ok(parse_porcelain(&out, &target_rel))
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

/// Map a two-letter porcelain status code to a stable status label.
pub(super) fn map_git_status(xy: &str) -> Option<&'static str> {
    if xy.len() != 2 {
        return None;
    }

    if xy == "??" {
        return Some("untracked");
    }
    if xy == "!!" {
        return Some("ignored");
    }
    if xy.contains('U') || xy == "AA" || xy == "DD" {
        return Some("conflict");
    }
    if xy.contains('R') {
        return Some("renamed");
    }
    if xy.contains('C') {
        return Some("copied");
    }
    if xy.contains('A') {
        return Some("added");
    }
    if xy.contains('D') {
        return Some("deleted");
    }
    if xy.contains('M') || xy.contains('T') {
        return Some("modified");
    }

    None
}

/// Parse `git status --porcelain=1 -z` output and map each changed path to
/// the name of the immediate entry it belongs to in `target_rel`.
///
/// Paths inside a subdirectory of the listed path are rolled up into a
/// `descendant` status on that subdirectory, matching the common file-tree
/// convention where folders show a dot when any child changed.
pub(super) fn parse_porcelain(output: &str, target_rel: &str) -> HashMap<String, String> {
    let prefix = if target_rel.is_empty() {
        String::new()
    } else {
        format!("{target_rel}/")
    };

    let mut by_name: HashMap<String, String> = HashMap::new();
    let mut records = output.split('\0').peekable();

    while let Some(record) = records.next() {
        if record.is_empty() || record.len() < 3 || &record[2..3] != " " {
            continue;
        }

        let xy = &record[0..2];
        let Some(status) = map_git_status(xy) else {
            continue;
        };

        let path = &record[3..];

        // Renames and copies are followed by the original path in the next
        // record; skip it and use the new (current) path.
        if status == "renamed" || status == "copied" {
            records.next();
        }

        let Some(rel) = path.strip_prefix(&prefix) else {
            continue;
        };

        if rel.is_empty() {
            continue;
        }

        if let Some((first, _)) = rel.split_once('/') {
            let first = first.to_string();
            if status == "ignored" {
                by_name
                    .entry(first)
                    .or_insert_with(|| "ignored".to_string());
            } else {
                by_name
                    .entry(first)
                    .and_modify(|v| {
                        if v == "ignored" {
                            *v = "descendant".to_string();
                        }
                    })
                    .or_insert_with(|| "descendant".to_string());
            }
        } else {
            by_name.insert(rel.to_string(), status.to_string());
        }
    }

    by_name
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
    use super::{map_git_status, parse_porcelain, parse_status};

    #[test]
    fn map_git_status_labels() {
        assert_eq!(map_git_status("??"), Some("untracked"));
        assert_eq!(map_git_status("!!"), Some("ignored"));
        assert_eq!(map_git_status(" M"), Some("modified"));
        assert_eq!(map_git_status("M "), Some("modified"));
        assert_eq!(map_git_status("MM"), Some("modified"));
        assert_eq!(map_git_status("A "), Some("added"));
        assert_eq!(map_git_status(" D"), Some("deleted"));
        assert_eq!(map_git_status("R "), Some("renamed"));
        assert_eq!(map_git_status(" R"), Some("renamed"));
        assert_eq!(map_git_status("C "), Some("copied"));
        assert_eq!(map_git_status(" C"), Some("copied"));
        assert_eq!(map_git_status("UU"), Some("conflict"));
        assert_eq!(map_git_status("AA"), Some("conflict"));
        assert_eq!(map_git_status("AU"), Some("conflict"));
        assert_eq!(map_git_status(" T"), Some("modified"));
        assert_eq!(map_git_status("  "), None);
    }

    #[test]
    fn parse_porcelain_maps_direct_and_descendant_statuses() {
        let out = " M a.txt\0?? b/c.txt\0R  new\0old\0!! ignored.log";
        let map = parse_porcelain(out, "");
        assert_eq!(map.get("a.txt"), Some(&"modified".to_string()));
        assert_eq!(map.get("b"), Some(&"descendant".to_string()));
        assert_eq!(map.get("new"), Some(&"renamed".to_string()));
        assert_eq!(map.get("ignored.log"), Some(&"ignored".to_string()));
        assert!(!map.contains_key("old"));
    }

    #[test]
    fn parse_porcelain_strips_target_prefix() {
        let out = " M sub/a.txt\0?? sub/b/c.txt";
        let map = parse_porcelain(out, "sub");
        assert_eq!(map.get("a.txt"), Some(&"modified".to_string()));
        assert_eq!(map.get("b"), Some(&"descendant".to_string()));
    }

    #[test]
    fn parse_porcelain_handles_paths_with_spaces_and_quotes() {
        let out = "?? file with space.txt\0?? quote\"inside.txt";
        let map = parse_porcelain(out, "");
        assert_eq!(
            map.get("file with space.txt"),
            Some(&"untracked".to_string())
        );
        assert_eq!(map.get("quote\"inside.txt"), Some(&"untracked".to_string()));
    }

    #[test]
    fn parse_porcelain_worktree_renames_and_ignored_descendants() {
        let out = " R new\0old\0!! build/out.o\0 M build/real.txt";
        let map = parse_porcelain(out, "");
        assert_eq!(map.get("new"), Some(&"renamed".to_string()));
        assert!(!map.contains_key("old"));
        // A dir with both ignored and non-ignored changes is a descendant.
        assert_eq!(map.get("build"), Some(&"descendant".to_string()));

        let out = "!! build/out.o";
        let map = parse_porcelain(out, "");
        assert_eq!(map.get("build"), Some(&"ignored".to_string()));

        let out = "!! build/";
        let map = parse_porcelain(out, "");
        assert_eq!(map.get("build"), Some(&"ignored".to_string()));
    }

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
