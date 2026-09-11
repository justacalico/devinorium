//! Working-tree changes: list, stage, unstage, and commit.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;

use super::{GitError, GitService};

/// A changed file in the index or the working tree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ChangeEntry {
    pub path: String,
    pub status: String,
    /// For renames and copies, the path the file was moved from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub orig_path: Option<String>,
}

/// Staged and unstaged changes plus tracking state for a repository.
#[derive(Debug, Serialize)]
pub struct ChangeList {
    pub branch: String,
    pub ahead: i64,
    pub behind: i64,
    pub staged: Vec<ChangeEntry>,
    pub unstaged: Vec<ChangeEntry>,
    /// Whether porcelain emitted a `# branch.ab` header. Absent means no
    /// upstream is configured; only then do we fall back to cached counts.
    #[serde(skip_serializing)]
    pub(crate) has_ab_header: bool,
}

/// The result of a successful `git commit`.
#[derive(Debug, Serialize)]
pub struct CommitResult {
    pub sha: String,
    pub subject: String,
}

impl GitService {
    /// List staged and unstaged changes using `git status --porcelain=2`.
    ///
    /// When `force` is true the repository detection is re-run first; the
    /// change list itself is always read live from git.
    pub async fn changes(&self, path: &Path, force: bool) -> Result<ChangeList, GitError> {
        let status = self.repo_status(path, force).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let out = self
            .run_with(
                path,
                &[
                    "status",
                    "--porcelain=2",
                    "--branch",
                    "-z",
                    "--untracked-files=all",
                    "--renames",
                ],
                Duration::from_secs(10),
            )
            .await?;
        let mut list = parse_change_list(&out);
        // Detached HEAD reports "(detached)"; keep the detected empty branch
        // so callers consistently treat the repo as branchless.
        if list.branch.is_empty() || list.branch == "(detached)" {
            list.branch = status.branch;
        }
        // branch.ab is only emitted when an upstream exists; absent means
        // no upstream, so use the cached tracking counts. A live +0 -0 is
        // fresher than the cache and must not be overwritten.
        if !list.has_ab_header {
            list.ahead = status.ahead;
            list.behind = status.behind;
        }
        // `git status` reports nested worktrees and embedded clones as
        // untracked directories. They are never real changes, and staging
        // them would record a gitlink, so hide them from the list.
        let embedded = embedded_repo_dirs(&out, &status.toplevel);
        if !embedded.is_empty() {
            list.unstaged
                .retain(|e| !embedded.iter().any(|d| e.path == format!("{d}/")));
        }
        Ok(list)
    }

    /// Stage paths (`git add`). With `all`, stage the whole working tree
    /// including deletions — except embedded repositories (nested worktrees
    /// and clones), which `git add -A` would otherwise record as gitlinks.
    ///
    /// Runs from the repo toplevel because porcelain paths are always
    /// repo-root-relative, and the project dir can be a subdirectory.
    /// Re-detects the repo (force) so a fresh `git init` isn't masked by a
    /// stale is_repo=false cache entry.
    pub async fn stage(&self, path: &Path, paths: &[String], all: bool) -> Result<(), GitError> {
        let status = self.repo_status(path, true).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let mut cmd = self.git_cmd(&status.toplevel);
        cmd.arg("add");
        if all {
            cmd.arg("-A").arg("--");
            for dir in self.embedded_repo_dirs_now(&status.toplevel).await {
                cmd.arg(format!(":(top,exclude){dir}"));
            }
        } else {
            let paths: Vec<&str> = paths
                .iter()
                .map(|p| p.as_str())
                .filter(|p| !p.is_empty())
                .collect();
            if paths.is_empty() {
                return Err(GitError::Other("no paths to stage".to_string()));
            }
            // Filenames can look like pathspec magic or globs; keep them
            // literal so `git add -- ':(exclude)x'` stages that file, not
            // the tree minus x.
            cmd.env("GIT_LITERAL_PATHSPECS", "1");
            cmd.arg("--").args(paths);
        }
        self.run(&mut cmd, Duration::from_secs(30)).await?;
        Ok(())
    }

    /// Unstage paths (`git reset -q -- <paths>`). With `all`, reset the whole
    /// index. Works on an unborn HEAD, unlike `git restore --staged`.
    pub async fn unstage(&self, path: &Path, paths: &[String], all: bool) -> Result<(), GitError> {
        let status = self.repo_status(path, true).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let mut cmd = self.git_cmd(&status.toplevel);
        cmd.arg("reset").arg("-q");
        if !all {
            let paths: Vec<&str> = paths
                .iter()
                .map(|p| p.as_str())
                .filter(|p| !p.is_empty())
                .collect();
            if paths.is_empty() {
                return Err(GitError::Other("no paths to unstage".to_string()));
            }
            cmd.env("GIT_LITERAL_PATHSPECS", "1");
            cmd.arg("--").args(paths);
        }
        self.run(&mut cmd, Duration::from_secs(30)).await?;
        Ok(())
    }

    /// Commit staged changes with `message`. With `all`, stage the whole
    /// working tree first (the equivalent of `git commit -a` plus untracked
    /// files, matching the panel's "commit everything" flow).
    pub async fn commit(
        &self,
        path: &Path,
        message: &str,
        all: bool,
    ) -> Result<CommitResult, GitError> {
        let status = self.repo_status(path, true).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let message = message.trim();
        if message.is_empty() {
            return Err(GitError::Other("commit message is required".to_string()));
        }
        if all {
            self.stage(path, &[], true).await?;
        }
        let mut cmd = self.git_cmd(path);
        cmd.arg("commit").arg("-m").arg(message);
        self.run(&mut cmd, Duration::from_secs(30)).await?;
        let sha = self
            .run_with(path, &["rev-parse", "HEAD"], Duration::from_secs(5))
            .await?
            .trim()
            .to_string();
        let subject = self
            .run_with(path, &["log", "-1", "--format=%s"], Duration::from_secs(5))
            .await
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| message.lines().next().unwrap_or("").to_string());
        self.invalidate(path);
        Ok(CommitResult { sha, subject })
    }
}

impl GitService {
    /// Embedded repo dirs under `toplevel`, discovered with a fresh
    /// `git status`. `--untracked-files=all` keeps untracked parent dirs
    /// expanded so a repo nested inside one is still found.
    async fn embedded_repo_dirs_now(&self, toplevel: &Path) -> Vec<String> {
        match self
            .run_with(
                toplevel,
                &["status", "--porcelain=2", "-z", "--untracked-files=all"],
                Duration::from_secs(10),
            )
            .await
        {
            Ok(out) => embedded_repo_dirs(&out, toplevel),
            Err(_) => Vec::new(),
        }
    }
}

/// Repo-relative paths of untracked directories in a porcelain v2 status
/// output that contain their own `.git` — nested worktrees and plain
/// embedded clones. `git add -A` would stage them as gitlinks, so they are
/// excluded from stage-all and hidden from the change list.
fn embedded_repo_dirs(status_out: &str, toplevel: &Path) -> Vec<String> {
    status_out
        .split('\0')
        .filter_map(|r| r.strip_prefix("? "))
        .filter(|d| d.ends_with('/'))
        .filter(|d| toplevel.join(d).join(".git").exists())
        .map(|d| d.trim_end_matches('/').to_string())
        .collect()
}

/// Map a single porcelain v2 index/worktree status letter to a label.
fn status_label(c: char) -> Option<&'static str> {
    Some(match c {
        'M' | 'T' => "modified",
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        'C' => "copied",
        'U' => "conflict",
        _ => return None,
    })
}

/// Parse `git status --porcelain=2 --branch -z` output into a [ChangeList].
///
/// Ordinary records (`1`) may appear in both lists when a file has staged and
/// unstaged changes. Rename/copy records (`2`) are followed by the origin
/// path in the next NUL-separated record. Unmerged records (`u`) report as
/// conflicts in the unstaged list. Ignored records (`!`) are skipped.
pub(super) fn parse_change_list(output: &str) -> ChangeList {
    let mut branch = String::new();
    let mut ahead = 0i64;
    let mut behind = 0i64;
    let mut has_ab_header = false;
    let mut staged = Vec::new();
    let mut unstaged = Vec::new();

    let mut records = output.split('\0');
    while let Some(record) = records.next() {
        if record.is_empty() {
            continue;
        }
        if let Some(header) = record.strip_prefix("# ") {
            if let Some(head) = header.strip_prefix("branch.head ") {
                branch = head.trim().to_string();
            } else if let Some(ab) = header.strip_prefix("branch.ab ") {
                has_ab_header = true;
                for part in ab.split(' ') {
                    if let Some(a) = part.strip_prefix('+') {
                        ahead = a.parse().unwrap_or(0);
                    } else if let Some(b) = part.strip_prefix('-') {
                        behind = b.parse().unwrap_or(0);
                    }
                }
            }
            continue;
        }

        let kind = record.as_bytes()[0];
        match kind {
            b'1' | b'2' | b'u' => {
                // Fields: 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                //         2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>
                //         u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let (max_fields, mid_fields) = match kind {
                    b'1' => (9, 6),
                    b'2' => (10, 7),
                    _ => (11, 8),
                };
                let mut it = record.splitn(max_fields, ' ');
                it.next();
                let xy = it.next().unwrap_or("");
                for _ in 0..mid_fields {
                    it.next();
                }
                let path = it.next().unwrap_or("").to_string();
                if path.is_empty() {
                    continue;
                }
                let orig_path = if kind == b'2' {
                    records.next().map(|s| s.to_string())
                } else {
                    None
                };
                let mut chars = xy.chars();
                let x = chars.next().unwrap_or('.');
                let y = chars.next().unwrap_or('.');
                if kind == b'u' {
                    unstaged.push(ChangeEntry {
                        path,
                        status: "conflict".to_string(),
                        orig_path: None,
                    });
                    continue;
                }
                if let Some(status) = status_label(x) {
                    staged.push(ChangeEntry {
                        path: path.clone(),
                        status: status.to_string(),
                        orig_path: orig_path.clone(),
                    });
                }
                if let Some(status) = status_label(y) {
                    unstaged.push(ChangeEntry {
                        path,
                        status: status.to_string(),
                        orig_path: None,
                    });
                }
            }
            b'?' => {
                let path = record.get(2..).unwrap_or("");
                if !path.is_empty() {
                    unstaged.push(ChangeEntry {
                        path: path.to_string(),
                        status: "untracked".to_string(),
                        orig_path: None,
                    });
                }
            }
            _ => {}
        }
    }

    staged.sort_by(|a, b| a.path.cmp(&b.path));
    unstaged.sort_by(|a, b| a.path.cmp(&b.path));
    ChangeList {
        branch,
        ahead,
        behind,
        staged,
        unstaged,
        has_ab_header,
    }
}

#[cfg(test)]
mod tests {
    use super::parse_change_list;

    #[test]
    fn parse_change_list_splits_staged_and_unstaged() {
        let out = "# branch.oid abc\0# branch.head main\0# branch.ab +2 -1\0\
                   1 M. N... 100644 100644 100644 aaa bbb staged.txt\0\
                   1 .M N... 100644 100644 100644 aaa bbb unstaged.txt\0\
                   1 MM N... 100644 100644 100644 aaa bbb both.txt\0\
                   ? new file.txt\0\
                   ! ignored.log\0";
        let list = parse_change_list(out);
        assert_eq!(list.branch, "main");
        assert_eq!(list.ahead, 2);
        assert_eq!(list.behind, 1);
        assert_eq!(list.staged.len(), 2);
        assert_eq!(list.staged[0].path, "both.txt");
        assert_eq!(list.staged[1].path, "staged.txt");
        assert_eq!(list.unstaged.len(), 3);
        assert_eq!(list.unstaged[0].path, "both.txt");
        assert_eq!(list.unstaged[1].path, "new file.txt");
        assert_eq!(list.unstaged[1].status, "untracked");
        assert_eq!(list.unstaged[2].path, "unstaged.txt");
        assert!(list.staged.iter().all(|e| e.orig_path.is_none()));
    }

    #[test]
    fn parse_change_list_rename_carries_orig_path() {
        let out = "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt\0old name.txt\0";
        let list = parse_change_list(out);
        assert_eq!(list.staged.len(), 1);
        assert_eq!(list.staged[0].path, "new name.txt");
        assert_eq!(list.staged[0].status, "renamed");
        assert_eq!(list.staged[0].orig_path.as_deref(), Some("old name.txt"));
        assert!(list.unstaged.is_empty());
    }

    #[test]
    fn parse_change_list_unmerged_is_conflict() {
        let out = "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt\0";
        let list = parse_change_list(out);
        assert!(list.staged.is_empty());
        assert_eq!(list.unstaged.len(), 1);
        assert_eq!(list.unstaged[0].status, "conflict");
    }

    #[test]
    fn parse_change_list_deleted_and_added() {
        let out = "1 D. N... 100644 000000 000000 aaa bbb gone.txt\0\
                   1 .D N... 100644 100644 000000 aaa bbb deleted.txt\0\
                   1 A. N... 000000 100644 100644 000 bbb added.txt\0";
        let list = parse_change_list(out);
        assert_eq!(list.staged.len(), 2);
        assert_eq!(list.staged[0].status, "added");
        assert_eq!(list.staged[1].status, "deleted");
        assert_eq!(list.unstaged.len(), 1);
        assert_eq!(list.unstaged[0].path, "deleted.txt");
    }
}
