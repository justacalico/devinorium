//! Compute a text diff between a working-tree file and its HEAD version.

use std::path::Path;
use std::time::Duration;

use crate::providers::FileDiff;

use super::{GitError, GitService};

/// Diffs are only produced for text files that are small enough to render
/// quickly in the inline diff widget. Files larger than this are still
/// readable through the normal content view.
pub(crate) const MAX_DIFF_BYTES: usize = 256 * 1024;
pub(crate) const MAX_DIFF_LINES: usize = 1000;

impl GitService {
    /// Return a [`FileDiff`] between `target` and the same path at `HEAD`.
    ///
    /// The repository is discovered from the target's own directory, so files
    /// inside linked worktrees diff against that checkout's `HEAD`.
    /// `new_text` is the current working-tree content. If the file is untracked
    /// or newly added, `old_text` is `None`. Non-UTF-8 or oversized files and
    /// files outside a git repository return `None`.
    pub async fn text_diff(
        &self,
        target: &Path,
        new_text: &str,
    ) -> Result<Option<FileDiff>, GitError> {
        if self.git.is_none() {
            return Ok(None);
        }
        if new_text.len() > MAX_DIFF_BYTES || new_text.lines().count() > MAX_DIFF_LINES {
            return Ok(None);
        }

        let target = tokio::fs::canonicalize(target)
            .await
            .map_err(|e| GitError::Other(e.to_string()))?;
        let dir = target.parent().unwrap_or(target.as_path());
        let repo = self.repo_status(dir, true).await?;
        if !repo.is_repo {
            return Ok(None);
        }

        let rel = target
            .strip_prefix(&repo.toplevel)
            .map_err(|_| GitError::Other("path outside repository".into()))?;
        let rel = rel.to_string_lossy().replace('\\', "/");
        if rel.is_empty() {
            return Ok(None);
        }

        let head_arg = format!("HEAD:{rel}");
        let old_text = match self
            .run_with(&repo.toplevel, &["show", &head_arg], Duration::from_secs(5))
            .await
        {
            Ok(s) => Some(s),
            Err(GitError::Other(msg))
                if msg.contains("not in 'HEAD'")
                    || msg.contains("does not exist in 'HEAD'")
                    || msg.contains("does not exist (neither on disk nor in the index)") =>
            {
                None
            }
            Err(GitError::NotRepo) => None,
            Err(e) => return Err(e),
        };

        if old_text
            .as_ref()
            .is_some_and(|o| o.len() > MAX_DIFF_BYTES || o.lines().count() > MAX_DIFF_LINES)
        {
            return Ok(None);
        }
        if old_text.as_deref() == Some(new_text) {
            return Ok(None);
        }

        Ok(Some(FileDiff {
            path: target.to_string_lossy().into_owned(),
            old_text,
            new_text: new_text.to_string(),
        }))
    }

    /// Diff for a change-list entry, for the git panel's inline preview.
    ///
    /// `rel` is the repo-relative path from `git status`; `orig_path` is the
    /// rename source when the entry is a rename. A staged entry diffs the
    /// index against `HEAD`; an unstaged entry diffs the working tree
    /// against the index (untracked files diff as all-new, deletions as
    /// all-removed). Returns `None` when the diff is unavailable — binary
    /// content, oversized files, or nothing to compare.
    pub async fn change_diff(
        &self,
        path: &Path,
        rel: &str,
        orig_path: Option<&str>,
        staged: bool,
        force: bool,
    ) -> Result<Option<FileDiff>, GitError> {
        if self.git.is_none() {
            return Err(GitError::NotEnabled);
        }
        let rel = super::changes::check_rel_path(rel)?;
        let orig = orig_path.map(super::changes::check_rel_path).transpose()?;
        let repo = self.repo_status(path, force).await?;
        if !repo.is_repo {
            return Err(GitError::NotRepo);
        }
        let top = repo.toplevel.clone();
        let top_canon = tokio::fs::canonicalize(&top)
            .await
            .unwrap_or_else(|_| top.clone());

        let (old_text, new_text) = if staged {
            // Index vs HEAD. The rename source is the HEAD blob when one is
            // recorded; a plain added file has no HEAD side at all.
            let mut old = match orig {
                Some(o) => self.show_blob(&top, &format!("HEAD:{o}")).await?,
                None => None,
            };
            if old.is_none() {
                old = self.show_blob(&top, &format!("HEAD:{rel}")).await?;
            }
            // A staged delete has no index blob. The explicit stage prefix
            // keeps a path like `0:foo` from being parsed as a stage spec.
            let new = self
                .show_blob(&top, &format!(":0:{rel}"))
                .await?
                .unwrap_or_default();
            (old, new)
        } else {
            // Working tree vs index. Renames find their base under the
            // origin's index entry; unmerged paths have no stage-0 blob so
            // HEAD is the base; untracked paths have no base at all.
            let mut old = self.show_blob(&top, &format!(":0:{rel}")).await?;
            if old.is_none() {
                if let Some(o) = orig {
                    old = self.show_blob(&top, &format!(":0:{o}")).await?;
                }
            }
            if old.is_none() {
                let in_index = !self
                    .run_literal(
                        &top,
                        &["ls-files", "-z", "--", rel.as_str()],
                        Duration::from_secs(5),
                    )
                    .await?
                    .is_empty();
                if in_index {
                    old = self.show_blob(&top, &format!("HEAD:{rel}")).await?;
                }
            }
            // Read the worktree copy through its canonical path so a
            // symlink — the leaf or any intermediate component — cannot
            // serve content from outside the repository. A symlinked leaf
            // stores its target path in the index blob, so the worktree
            // side is the link target, not the resolved file's content.
            let abs = top.join(rel.as_str());
            let new = match tokio::fs::symlink_metadata(&abs).await {
                Ok(meta) if meta.file_type().is_symlink() => tokio::fs::read_link(&abs)
                    .await
                    .map(|t| t.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                _ => match tokio::fs::canonicalize(&abs).await {
                    Ok(canon) if canon.starts_with(&top_canon) => {
                        match tokio::fs::read(&canon).await {
                            Ok(bytes) => match String::from_utf8(bytes) {
                                Ok(t) => t,
                                Err(_) => return Ok(None),
                            },
                            Err(_) => String::new(),
                        }
                    }
                    Ok(_) => return Ok(None),
                    Err(_) => String::new(),
                },
            };
            (old, new)
        };

        // `git show` output arrives lossy-decoded; a NUL byte is the same
        // signal `git diff` uses to call a file binary.
        let binary = |t: &Option<String>| t.as_deref().is_some_and(|s| s.contains('\0'));
        if binary(&old_text) || new_text.contains('\0') {
            return Ok(None);
        }
        let oversized = |t: &str| t.len() > MAX_DIFF_BYTES || t.lines().count() > MAX_DIFF_LINES;
        if old_text.as_deref().is_some_and(oversized) || oversized(&new_text) {
            return Ok(None);
        }
        if old_text.as_deref() == Some(new_text.as_str()) {
            return Ok(None);
        }

        Ok(Some(FileDiff {
            path: top.join(rel.as_str()).to_string_lossy().into_owned(),
            old_text,
            new_text,
        }))
    }

    /// Read a blob via `git show <spec>` (e.g. `HEAD:path` or `:0:path`).
    /// `Ok(None)` means the blob legitimately does not exist — a staged add
    /// has no HEAD side, a staged delete has no index side, unmerged paths
    /// have no stage-0 blob. Timeouts and other git failures propagate so
    /// they cannot masquerade as an added/deleted file.
    async fn show_blob(&self, cwd: &Path, spec: &str) -> Result<Option<String>, GitError> {
        match self
            .run_literal(cwd, &["show", spec], Duration::from_secs(5))
            .await
        {
            Ok(s) => Ok(Some(s)),
            Err(GitError::Other(msg))
                // Missing-blob errors are always `fatal: path '...'` —
                // requiring that prefix keeps a real failure (e.g. a
                // corrupt object, whose message can also contain
                // "does not exist") from being swallowed as "no blob".
                if (msg.starts_with("fatal: path '")
                    && (msg.contains("does not exist")
                        || msg.contains("not in 'HEAD'")
                        || msg.contains("not in the index")
                        || msg.contains("did not match")
                        || msg.contains("not at stage 0")
                        || msg.contains("is unmerged")))
                    || msg.contains("invalid object name")
                    || msg.contains("ambiguous argument") =>
            {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tokio::process::Command;

    use super::super::{GitError, GitService};

    async fn init_repo(dir: &std::path::Path) {
        let git = GitService::new();
        assert!(git.is_enabled(), "git binary required for diff tests");

        let _ = std::fs::remove_dir_all(dir.join(".git"));
        run_git(dir, &["init"]).await;
        run_git(dir, &["config", "user.email", "test@example.com"]).await;
        run_git(dir, &["config", "user.name", "Test"]).await;
    }

    async fn run_git(dir: &std::path::Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .current_dir(dir)
            .env("LC_ALL", "C")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GCM_INTERACTIVE", "never")
            .env("SSH_ASKPASS_REQUIRE", "never")
            .args(args)
            .output()
            .await
            .expect("git command");
        assert!(
            out.status.success(),
            "git {:?} failed: {:?}",
            args,
            out.stderr
        );
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    async fn commit_all(dir: &std::path::Path, message: &str) {
        run_git(dir, &["add", "."]).await;
        run_git(dir, &["commit", "--allow-empty", "-m", message]).await;
    }

    #[tokio::test]
    async fn text_diff_for_modified_file() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;

        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;

        tokio::fs::write(&file, "fn main() { println!(\"hi\"); }\n")
            .await
            .unwrap();

        let git = GitService::new();
        let diff = git
            .text_diff(&file, "fn main() { println!(\"hi\"); }\n")
            .await
            .unwrap();

        assert!(diff.is_some());
        let diff = diff.unwrap();
        assert_eq!(diff.path, file.to_string_lossy());
        assert_eq!(diff.old_text.as_deref(), Some("fn main() {}\n"));
        assert_eq!(diff.new_text, "fn main() { println!(\"hi\"); }\n");
    }

    #[tokio::test]
    async fn text_diff_for_new_file() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;

        let file = tmp.path().join("new.rs");
        tokio::fs::write(&file, "pub fn x() {}\n").await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, "pub fn x() {}\n").await.unwrap();

        assert!(diff.is_some());
        assert_eq!(diff.unwrap().old_text, None);
    }

    #[tokio::test]
    async fn text_diff_returns_none_for_unchanged_file() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;

        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;

        let git = GitService::new();
        let diff = git.text_diff(&file, "fn main() {}\n").await.unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_returns_none_outside_repo() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("orphan.txt");
        tokio::fs::write(&file, "hello\n").await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, "hello\n").await.unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_returns_none_when_new_text_exceeds_line_limit() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;

        let file = tmp.path().join("big.txt");
        let lines = (0..super::MAX_DIFF_LINES + 1)
            .map(|i| format!("line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        tokio::fs::write(&file, &lines).await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, &lines).await.unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_returns_none_when_old_text_exceeds_line_limit() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;

        let file = tmp.path().join("big.txt");
        let old_lines = (0..super::MAX_DIFF_LINES + 1)
            .map(|i| format!("old {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        tokio::fs::write(&file, &old_lines).await.unwrap();
        commit_all(tmp.path(), "initial").await;

        let new_lines = (0..5)
            .map(|i| format!("new {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        tokio::fs::write(&file, &new_lines).await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, &new_lines).await.unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_returns_none_when_new_text_exceeds_byte_limit() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;

        let file = tmp.path().join("huge.txt");
        let body = (0..super::MAX_DIFF_BYTES + 1)
            .map(|_| 'x')
            .collect::<String>();
        tokio::fs::write(&file, &body).await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, &body).await.unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_resolves_file_in_subdir() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;

        let sub = tmp.path().join("src");
        tokio::fs::create_dir(&sub).await.unwrap();
        let file = sub.join("lib.rs");
        tokio::fs::write(&file, "pub mod a;\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;

        tokio::fs::write(&file, "pub mod b;\n").await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, "pub mod b;\n").await.unwrap();

        assert!(diff.is_some());
        assert_eq!(diff.unwrap().old_text.as_deref(), Some("pub mod a;\n"));
    }

    #[tokio::test]
    async fn change_diff_unstaged_modified() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        tokio::fs::write(&file, "fn main() { 1 }\n").await.unwrap();

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "main.rs", None, false, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("fn main() {}\n"));
        assert_eq!(diff.new_text, "fn main() { 1 }\n");
    }

    #[tokio::test]
    async fn change_diff_staged_modified_diffs_against_head() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        tokio::fs::write(&file, "fn main() { 1 }\n").await.unwrap();
        run_git(tmp.path(), &["add", "main.rs"]).await;

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "main.rs", None, true, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("fn main() {}\n"));
        assert_eq!(diff.new_text, "fn main() { 1 }\n");
    }

    #[tokio::test]
    async fn change_diff_unstaged_uses_index_as_base() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "a\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        // Stage "b", then edit to "c" in the worktree: the unstaged diff is
        // index (b) vs worktree (c), not HEAD (a).
        tokio::fs::write(&file, "b\n").await.unwrap();
        run_git(tmp.path(), &["add", "main.rs"]).await;
        tokio::fs::write(&file, "c\n").await.unwrap();

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "main.rs", None, false, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("b\n"));
        assert_eq!(diff.new_text, "c\n");
    }

    #[tokio::test]
    async fn change_diff_untracked_file_is_all_added() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;
        tokio::fs::write(tmp.path().join("new.txt"), "fresh\n")
            .await
            .unwrap();

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "new.txt", None, false, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text, None);
        assert_eq!(diff.new_text, "fresh\n");
    }

    #[tokio::test]
    async fn change_diff_staged_add_has_no_old_side() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;
        tokio::fs::write(tmp.path().join("added.txt"), "added\n")
            .await
            .unwrap();
        run_git(tmp.path(), &["add", "added.txt"]).await;

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "added.txt", None, true, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text, None);
        assert_eq!(diff.new_text, "added\n");
    }

    #[tokio::test]
    async fn change_diff_unstaged_delete_is_all_removed() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        tokio::fs::remove_file(&file).await.unwrap();

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "main.rs", None, false, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("fn main() {}\n"));
        assert_eq!(diff.new_text, "");
    }

    #[tokio::test]
    async fn change_diff_staged_delete_is_all_removed() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("main.rs");
        tokio::fs::write(&file, "fn main() {}\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        run_git(tmp.path(), &["rm", "-q", "main.rs"]).await;

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "main.rs", None, true, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("fn main() {}\n"));
        assert_eq!(diff.new_text, "");
    }

    #[tokio::test]
    async fn change_diff_staged_rename_uses_orig_blob() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        let file = tmp.path().join("old.txt");
        tokio::fs::write(&file, "old content\n").await.unwrap();
        commit_all(tmp.path(), "initial").await;
        run_git(tmp.path(), &["mv", "old.txt", "new.txt"]).await;
        // Tweak after the rename so staged content differs from HEAD.
        tokio::fs::write(tmp.path().join("new.txt"), "new content\n")
            .await
            .unwrap();
        run_git(tmp.path(), &["add", "new.txt"]).await;

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "new.txt", Some("old.txt"), true, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(diff.old_text.as_deref(), Some("old content\n"));
        assert_eq!(diff.new_text, "new content\n");
    }

    #[tokio::test]
    async fn change_diff_binary_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;
        tokio::fs::write(tmp.path().join("bin.dat"), b"a\0b\0".as_slice())
            .await
            .unwrap();

        let git = GitService::new();
        let diff = git
            .change_diff(tmp.path(), "bin.dat", None, false, false)
            .await
            .unwrap();
        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn change_diff_rejects_bad_paths_and_non_repo() {
        let tmp = tempfile::tempdir().unwrap();
        init_repo(tmp.path()).await;
        commit_all(tmp.path(), "initial").await;

        let git = GitService::new();
        let err = git
            .change_diff(tmp.path(), "../escape", None, false, false)
            .await
            .unwrap_err();
        assert!(matches!(err, GitError::Other(_)));

        let outside = tempfile::tempdir().unwrap();
        let err = git
            .change_diff(outside.path(), "a.txt", None, false, false)
            .await
            .unwrap_err();
        assert!(matches!(err, GitError::NotRepo));
    }

    #[test]
    fn path_rel_handles_backslashes() {
        // Quick unit check for the rel string conversion without touching git.
        let repo = PathBuf::from("/repo");
        let target = PathBuf::from("/repo/src\\main.rs");
        let rel = target
            .strip_prefix(&repo)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        assert_eq!(rel, "src/main.rs");
    }
}
