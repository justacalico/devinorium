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

    /// Discard changes for repo-relative paths.
    ///
    /// `staged` selects which side is thrown away. A staged entry is reset
    /// to `HEAD` in both the index and the working tree (`git checkout
    /// HEAD -- <path>`); a path absent from `HEAD` — a staged add or a
    /// rename target — has its index entry removed and is deleted. An
    /// unstaged entry is restored from the index (`git checkout --
    /// <path>`), which keeps staged content; a path with no index entry is
    /// untracked and is deleted. Unmerged paths have no stage-0 blob, so
    /// they resolve to `HEAD`, or are removed entirely when `HEAD` never
    /// contained them.
    ///
    /// Renames are discarded by passing both the new path and the
    /// `orig_path`: the new file is removed and the original is restored.
    pub async fn discard(
        &self,
        path: &Path,
        paths: &[String],
        staged: bool,
    ) -> Result<(), GitError> {
        let status = self.repo_status(path, true).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        // Validate everything up front so a bad path cannot leave a
        // half-applied discard behind.
        let rels: Vec<String> = paths
            .iter()
            .map(|p| check_rel_path(p))
            .collect::<Result<_, _>>()?;
        // On an unborn branch nothing is in HEAD; every staged path takes
        // the delete route below.
        let head_exists = self
            .run_with(
                &status.toplevel,
                &["rev-parse", "--verify", "-q", "HEAD"],
                Duration::from_secs(5),
            )
            .await
            .is_ok();
        let top_canon = tokio::fs::canonicalize(&status.toplevel)
            .await
            .unwrap_or_else(|_| status.toplevel.clone());

        for rel in rels {
            if !staged {
                // Unstaged row: worktree back to the index.
                if self.in_index(&status.toplevel, &rel).await? {
                    if self.is_unmerged(&status.toplevel, &rel).await? {
                        // Unmerged path: resolve to HEAD, or drop it when
                        // HEAD never had the file (an add/add conflict).
                        if head_exists && self.in_head(&status.toplevel, &rel).await? {
                            self.run_literal(
                                &status.toplevel,
                                &["checkout", "HEAD", "--", rel.as_str()],
                                Duration::from_secs(30),
                            )
                            .await?;
                        } else {
                            self.remove_index_and_worktree(&status.toplevel, &top_canon, &rel)
                                .await?;
                        }
                    } else {
                        self.run_literal(
                            &status.toplevel,
                            &["checkout", "--", rel.as_str()],
                            Duration::from_secs(30),
                        )
                        .await?;
                    }
                    continue;
                }
                // No index entry: untracked (or a worktree file recreated
                // over a staged delete) — remove it.
                self.remove_worktree_path(&status.toplevel, &top_canon, &rel)
                    .await?;
                continue;
            }

            // Staged row: index and worktree back to HEAD.
            if head_exists && self.in_head(&status.toplevel, &rel).await? {
                self.run_literal(
                    &status.toplevel,
                    &["checkout", "HEAD", "--", rel.as_str()],
                    Duration::from_secs(30),
                )
                .await?;
                continue;
            }
            // Not in HEAD: drop any index entry (staged add, rename
            // target), then remove the file if it is still on disk.
            if self.in_index(&status.toplevel, &rel).await? {
                self.remove_index_and_worktree(&status.toplevel, &top_canon, &rel)
                    .await?;
            } else {
                self.remove_worktree_path(&status.toplevel, &top_canon, &rel)
                    .await?;
            }
        }
        Ok(())
    }

    /// Whether `rel` has any index entry (any stage, so conflicts count).
    async fn in_index(&self, toplevel: &Path, rel: &str) -> Result<bool, GitError> {
        Ok(!self
            .run_literal(
                toplevel,
                &["ls-files", "-z", "--", rel],
                Duration::from_secs(5),
            )
            .await?
            .is_empty())
    }

    /// Whether `rel` has conflicted (unmerged) index entries.
    async fn is_unmerged(&self, toplevel: &Path, rel: &str) -> Result<bool, GitError> {
        Ok(!self
            .run_literal(
                toplevel,
                &["ls-files", "-u", "-z", "--", rel],
                Duration::from_secs(5),
            )
            .await?
            .is_empty())
    }

    /// Whether `rel` exists in `HEAD`'s tree.
    async fn in_head(&self, toplevel: &Path, rel: &str) -> Result<bool, GitError> {
        Ok(!self
            .run_literal(
                toplevel,
                &["ls-tree", "-z", "HEAD", "--", rel],
                Duration::from_secs(5),
            )
            .await?
            .is_empty())
    }

    /// Drop the index entry and worktree content for a path HEAD never
    /// had — a staged add, rename target, or conflicted add.
    ///
    /// `git rm -rf` deletes the worktree path itself, so when the delete
    /// cannot be proven safe — a symlinked parent pointing outside the
    /// worktree, or an embedded repository whose `.git` it would wipe —
    /// only the index entry is dropped (`rm --cached`) and the worktree
    /// is left alone.
    async fn remove_index_and_worktree(
        &self,
        toplevel: &Path,
        top_canon: &Path,
        rel: &str,
    ) -> Result<(), GitError> {
        let abs = toplevel.join(rel);
        let contained = match abs.parent() {
            Some(parent) => match tokio::fs::canonicalize(parent).await {
                Ok(canon) => canon.starts_with(top_canon),
                Err(_) => false,
            },
            None => false,
        };
        let is_dir = tokio::fs::symlink_metadata(&abs)
            .await
            .map(|m| m.is_dir())
            .unwrap_or(false);
        if contained && !(is_dir && dir_contains_repo(&abs)) {
            self.run_literal(
                toplevel,
                &["rm", "-rf", "-q", "--", rel],
                Duration::from_secs(30),
            )
            .await?;
            return self.remove_worktree_path(toplevel, top_canon, rel).await;
        }
        self.run_literal(
            toplevel,
            &["rm", "-rf", "-q", "--cached", "--", rel],
            Duration::from_secs(30),
        )
        .await
        .map(|_| ())
    }

    /// Remove a worktree path that has no HEAD/index entry to restore —
    /// an untracked file or directory.
    ///
    /// The canonical parent must stay inside the worktree so a symlinked
    /// intermediate component cannot redirect the delete outside the repo
    /// (the leaf itself may be a symlink; removing it only drops the
    /// link). A directory that is itself a repository is refused outright,
    /// like `git clean` without `-ff`.
    async fn remove_worktree_path(
        &self,
        toplevel: &Path,
        top_canon: &Path,
        rel: &str,
    ) -> Result<(), GitError> {
        let abs = toplevel.join(rel);
        let Ok(meta) = tokio::fs::symlink_metadata(&abs).await else {
            return Ok(());
        };
        let contained = match abs.parent() {
            Some(parent) => match tokio::fs::canonicalize(parent).await {
                Ok(canon) => canon.starts_with(top_canon),
                Err(_) => false,
            },
            None => false,
        };
        if !contained {
            return Err(GitError::Other(format!("path escapes repository: {rel}")));
        }
        if meta.is_dir() {
            // Refuse to wipe a nested repository anywhere in the subtree,
            // not only at the top — `git clean` needs `-ff` for that.
            if dir_contains_repo(&abs) {
                return Err(GitError::Other(format!(
                    "refusing to delete embedded repository: {rel}"
                )));
            }
            tokio::fs::remove_dir_all(&abs)
                .await
                .map_err(|e| GitError::Other(e.to_string()))
        } else {
            tokio::fs::remove_file(&abs)
                .await
                .map_err(|e| GitError::Other(e.to_string()))
        }
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

/// Validate a repo-relative path taken from an API request before using it
/// as a git pathspec or joining it to the toplevel.
///
/// Porcelain paths are always slash-separated and relative; anything
/// absolute, empty, containing `..`, or touching a hidden metadata dir
/// (`.git`, `.devinorium-attachments`) is rejected. The returned string is
/// rebuilt from normalized components so `a/./b` and `a//b` operate on
/// `a/b` instead of silently missing every git lookup.
pub(super) fn check_rel_path(path: &str) -> Result<String, GitError> {
    let rel = path.trim_end_matches('/');
    if rel.trim().is_empty() || Path::new(rel).is_absolute() {
        return Err(GitError::Other(format!("invalid path: {path}")));
    }
    let mut parts: Vec<String> = Vec::new();
    for component in Path::new(rel).components() {
        let std::path::Component::Normal(name) = component else {
            return Err(GitError::Other(format!("invalid path: {path}")));
        };
        let name = name.to_string_lossy();
        // `.git` must also be caught under Windows name folding: case
        // variants and trailing dots/spaces resolve to it there. The same
        // folding makes `.. ` or `. ` act as traversal on Windows, and a
        // name like `x ` indistinguishable from `x`, so any component
        // whose folded form changes meaning is rejected.
        let folded = name.trim_end_matches(['.', ' ']);
        if folded.is_empty()
            || folded == "."
            || folded == ".."
            || name.contains('\0')
            || crate::security::paths::HIDDEN_NAMES
                .iter()
                .any(|h| folded.eq_ignore_ascii_case(h))
            || (cfg!(windows) && folded != name)
        {
            return Err(GitError::Other(format!("invalid path: {path}")));
        }
        parts.push(name.into_owned());
    }
    if parts.is_empty() {
        return Err(GitError::Other(format!("invalid path: {path}")));
    }
    Ok(parts.join("/"))
}

/// Whether a directory tree contains a `.git` entry — an embedded repo or
/// linked worktree whose history a recursive delete would destroy. A
/// `.git` file (linked worktree) counts, not just a directory. Symlinked
/// dirs are not followed: the delete would only remove the link, and
/// following one could wander outside the repository.
fn dir_contains_repo(dir: &Path) -> bool {
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for entry in entries.flatten() {
            if entry.file_name() == ".git" {
                return true;
            }
            let Ok(ft) = entry.file_type() else {
                continue;
            };
            if ft.is_dir() && !ft.is_symlink() {
                stack.push(entry.path());
            }
        }
    }
    false
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

/// Reject API-supplied paths that escape the repo or touch metadata dirs.
#[cfg(test)]
mod path_tests {
    use super::{check_rel_path, GitError};

    #[test]
    fn rejects_bad_paths() {
        for p in [
            "",
            "   ",
            "/abs/path",
            "../escape",
            "a/../b",
            ".git/config",
            "sub/.git/x",
            ".GIT/config",
            ".git./x",
            "a/.devinorium-attachments/b",
            ".devinorium-attachments/a",
            ".",
            "./a",
            ".. ",
            ". ",
            ".. .",
            "...",
            "a/.. /b",
            "a/\0b",
        ] {
            assert!(
                matches!(check_rel_path(p), Err(GitError::Other(_))),
                "expected {p:?} to be rejected"
            );
        }
    }

    #[test]
    fn accepts_normal_paths() {
        assert_eq!(check_rel_path("a.txt").unwrap(), "a.txt");
        assert_eq!(check_rel_path("src/deep/f.rs").unwrap(), "src/deep/f.rs");
        assert_eq!(check_rel_path("dir/").unwrap(), "dir");
        // Whitespace inside a name is kept: it is a real filename, not
        // something to silently retarget onto a different file.
        assert_eq!(check_rel_path(" spaced .txt ").unwrap(), " spaced .txt ");
    }

    #[test]
    fn normalizes_dot_and_double_separators() {
        assert_eq!(check_rel_path("a/./b").unwrap(), "a/b");
        assert_eq!(check_rel_path("a//b").unwrap(), "a/b");
        assert_eq!(check_rel_path("a/b/").unwrap(), "a/b");
    }
}

#[cfg(test)]
mod discard_tests {
    use std::path::Path;
    use std::process::Command;

    use tempfile::TempDir;

    use super::super::GitService;

    fn git_cli(args: &[&str], cwd: &Path) {
        let out = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .env("GIT_AUTHOR_NAME", "Test")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "Test")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .env("GIT_LITERAL_PATHSPECS", "1")
            .output()
            .expect("git command failed");
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn make_repo() -> TempDir {
        let tmp = TempDir::new().unwrap();
        git_cli(&["init"], tmp.path());
        git_cli(&["config", "user.email", "test@example.com"], tmp.path());
        git_cli(&["config", "user.name", "Test"], tmp.path());
        std::fs::write(tmp.path().join("file.txt"), "hello\n").unwrap();
        git_cli(&["add", "file.txt"], tmp.path());
        git_cli(&["commit", "-m", "initial"], tmp.path());
        tmp
    }

    fn status_porcelain(dir: &Path) -> String {
        let out = Command::new("git")
            .args(["status", "--porcelain=2"])
            .current_dir(dir)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    #[tokio::test]
    async fn discard_restores_modified_file() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("file.txt"), "changed\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["file.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "hello\n"
        );
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_restores_deleted_file() {
        let tmp = make_repo();
        std::fs::remove_file(tmp.path().join("file.txt")).unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["file.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "hello\n"
        );
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_removes_untracked_file() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("new.txt"), "new\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["new.txt".to_string()], false)
            .await
            .unwrap();

        assert!(!tmp.path().join("new.txt").exists());
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_removes_staged_added_file() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("added.txt"), "added\n").unwrap();
        git_cli(&["add", "added.txt"], tmp.path());

        let svc = GitService::new();
        svc.discard(tmp.path(), &["added.txt".to_string()], true)
            .await
            .unwrap();

        assert!(!tmp.path().join("added.txt").exists());
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_reverts_staged_and_worktree_edits() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("file.txt"), "staged\n").unwrap();
        git_cli(&["add", "file.txt"], tmp.path());
        std::fs::write(tmp.path().join("file.txt"), "worktree\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["file.txt".to_string()], true)
            .await
            .unwrap();

        // Both the staged and the unstaged edit are gone.
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "hello\n"
        );
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_reverts_staged_rename() {
        let tmp = make_repo();
        git_cli(&["mv", "file.txt", "renamed.txt"], tmp.path());

        let svc = GitService::new();
        svc.discard(
            tmp.path(),
            &["renamed.txt".to_string(), "file.txt".to_string()],
            true,
        )
        .await
        .unwrap();

        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "hello\n"
        );
        assert!(!tmp.path().join("renamed.txt").exists());
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_resolves_conflict_to_head() {
        let tmp = make_repo();
        git_cli(&["checkout", "-b", "other"], tmp.path());
        std::fs::write(tmp.path().join("file.txt"), "other\n").unwrap();
        git_cli(&["commit", "-am", "other"], tmp.path());
        git_cli(&["checkout", "-"], tmp.path());
        std::fs::write(tmp.path().join("file.txt"), "ours\n").unwrap();
        git_cli(&["commit", "-am", "ours"], tmp.path());
        let _ = Command::new("git")
            .args(["merge", "other"])
            .current_dir(tmp.path())
            .output()
            .unwrap();
        assert!(status_porcelain(tmp.path()).contains("u "));

        let svc = GitService::new();
        svc.discard(tmp.path(), &["file.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "ours\n"
        );
        assert!(status_porcelain(tmp.path()).trim().is_empty());
        // The merge state itself is left for the user to resolve.
        assert!(tmp.path().join(".git/MERGE_HEAD").exists());
    }

    #[tokio::test]
    async fn discard_keeps_other_changes() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("file.txt"), "changed\n").unwrap();
        std::fs::write(tmp.path().join("keep.txt"), "keep\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["file.txt".to_string()], false)
            .await
            .unwrap();

        assert!(tmp.path().join("keep.txt").exists());
        let status = status_porcelain(tmp.path());
        assert!(status.contains("keep.txt"));
        assert!(!status.contains("file.txt"));
    }

    #[tokio::test]
    async fn discard_rejects_traversal_and_hidden_paths() {
        let tmp = make_repo();
        let svc = GitService::new();
        for p in ["../x", ".git/config", "/abs", "", ".GIT/config"] {
            let err = svc
                .discard(tmp.path(), &[p.to_string()], false)
                .await
                .unwrap_err();
            assert!(matches!(err, super::GitError::Other(_)), "{p}");
        }
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("file.txt")).unwrap(),
            "hello\n"
        );
    }

    #[tokio::test]
    async fn discard_on_unborn_head_removes_staged_file() {
        let tmp = TempDir::new().unwrap();
        git_cli(&["init"], tmp.path());
        git_cli(&["config", "user.email", "test@example.com"], tmp.path());
        git_cli(&["config", "user.name", "Test"], tmp.path());
        std::fs::write(tmp.path().join("f.txt"), "x\n").unwrap();
        git_cli(&["add", "f.txt"], tmp.path());

        let svc = GitService::new();
        svc.discard(tmp.path(), &["f.txt".to_string()], true)
            .await
            .unwrap();

        assert!(!tmp.path().join("f.txt").exists());
        assert!(status_porcelain(tmp.path()).trim().is_empty());
    }

    #[tokio::test]
    async fn discard_unstaged_keeps_staged_add_content() {
        // A staged add with further worktree edits shows two rows; the
        // unstaged row's discard restores the worktree from the index, it
        // must not delete the file.
        let tmp = make_repo();
        let file = tmp.path().join("added.txt");
        std::fs::write(&file, "staged\n").unwrap();
        git_cli(&["add", "added.txt"], tmp.path());
        std::fs::write(&file, "worktree\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["added.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(std::fs::read_to_string(&file).unwrap(), "staged\n");
        let status = status_porcelain(tmp.path());
        assert!(status.contains("added.txt"), "{status}");
        assert!(status.contains("1 A."), "{status}");
    }

    #[tokio::test]
    async fn discard_unstaged_rename_keeps_staged_rename() {
        // Same for a staged rename: discarding the unstaged row drops the
        // worktree edit but keeps the rename.
        let tmp = make_repo();
        git_cli(&["mv", "file.txt", "renamed.txt"], tmp.path());
        std::fs::write(tmp.path().join("renamed.txt"), "edited\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["renamed.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(tmp.path().join("renamed.txt")).unwrap(),
            "hello\n"
        );
        let status = status_porcelain(tmp.path());
        assert!(status.contains("R."), "{status}");
        assert!(status.contains("renamed.txt"), "{status}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn discard_refuses_symlink_escape() {
        // An intermediate symlink component must not let a repo-relative
        // path delete files outside the worktree.
        let tmp = make_repo();
        let outside = TempDir::new().unwrap();
        let victim = outside.path().join("victim.txt");
        std::fs::write(&victim, "keep me\n").unwrap();
        std::os::unix::fs::symlink(outside.path(), tmp.path().join("link")).unwrap();

        let svc = GitService::new();
        let err = svc
            .discard(tmp.path(), &["link/victim.txt".to_string()], false)
            .await
            .unwrap_err();
        assert!(matches!(err, super::GitError::Other(_)));
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep me\n");
    }

    #[tokio::test]
    async fn discard_refuses_embedded_repo_dir() {
        // The change list hides embedded repositories; discard must not
        // accept one either.
        let tmp = make_repo();
        let nested = tmp.path().join("nested");
        std::fs::create_dir(&nested).unwrap();
        git_cli(&["init"], &nested);
        std::fs::write(nested.join("inner.txt"), "x\n").unwrap();

        let svc = GitService::new();
        let err = svc
            .discard(tmp.path(), &["nested".to_string()], false)
            .await
            .unwrap_err();
        assert!(matches!(err, super::GitError::Other(_)));
        assert!(nested.join("inner.txt").exists());
    }

    #[tokio::test]
    async fn discard_staged_embedded_repo_keeps_git_dir() {
        // A staged gitlink (an embedded clone added to the index) must not
        // have its worktree removed by `git rm -rf` — that would wipe the
        // nested repository's `.git`. Only the index entry is dropped.
        let tmp = make_repo();
        let nested = tmp.path().join("nested");
        std::fs::create_dir(&nested).unwrap();
        git_cli(&["init"], &nested);
        std::fs::write(nested.join("inner.txt"), "x\n").unwrap();
        git_cli(&["add", "inner.txt"], &nested);
        git_cli(&["commit", "-m", "inner"], &nested);
        git_cli(&["add", "nested"], tmp.path());
        let indexed = || {
            let out = Command::new("git")
                .args(["ls-files", "-z", "--", "nested"])
                .current_dir(tmp.path())
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout).to_string()
        };
        assert_eq!(indexed(), "nested\0");

        let svc = GitService::new();
        svc.discard(tmp.path(), &["nested".to_string()], true)
            .await
            .unwrap();

        assert!(nested.join(".git").exists());
        assert!(nested.join("inner.txt").exists());
        assert!(indexed().is_empty());
    }

    #[tokio::test]
    async fn discard_refuses_dir_containing_nested_repo() {
        // A directory path is only reachable through the API, but a
        // recursive delete must still not wipe a repository nested deeper
        // inside it.
        let tmp = make_repo();
        let inner = tmp.path().join("outer/inner");
        std::fs::create_dir_all(&inner).unwrap();
        git_cli(&["init"], &inner);
        std::fs::write(tmp.path().join("outer/plain.txt"), "x\n").unwrap();

        let svc = GitService::new();
        let err = svc
            .discard(tmp.path(), &["outer".to_string()], false)
            .await
            .unwrap_err();
        assert!(matches!(err, super::GitError::Other(_)));
        assert!(inner.join(".git").exists());
        assert!(tmp.path().join("outer/plain.txt").exists());
    }

    #[tokio::test]
    async fn discard_normalizes_double_separator() {
        let tmp = make_repo();
        let sub = tmp.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("f.txt"), "orig\n").unwrap();
        git_cli(&["add", "sub/f.txt"], tmp.path());
        git_cli(&["commit", "-m", "sub"], tmp.path());
        std::fs::write(sub.join("f.txt"), "dirty\n").unwrap();

        let svc = GitService::new();
        svc.discard(tmp.path(), &["sub//f.txt".to_string()], false)
            .await
            .unwrap();

        assert_eq!(
            std::fs::read_to_string(sub.join("f.txt")).unwrap(),
            "orig\n"
        );
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
