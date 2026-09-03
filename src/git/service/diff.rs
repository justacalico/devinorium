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
    /// `root` is the project or home directory used to resolve the repository.
    /// `new_text` is the current working-tree content. If the file is untracked
    /// or newly added, `old_text` is `None`. Non-UTF-8 or oversized files and
    /// files outside a git repository return `None`.
    pub async fn text_diff(
        &self,
        target: &Path,
        root: &Path,
        new_text: &str,
    ) -> Result<Option<FileDiff>, GitError> {
        if self.git.is_none() {
            return Ok(None);
        }
        if new_text.len() > MAX_DIFF_BYTES || new_text.lines().count() > MAX_DIFF_LINES {
            return Ok(None);
        }

        let repo = self.repo_status(root, true).await?;
        if !repo.is_repo {
            return Ok(None);
        }

        let target = tokio::fs::canonicalize(target)
            .await
            .map_err(|e| GitError::Other(e.to_string()))?;
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
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tokio::process::Command;

    use super::super::GitService;

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
            .text_diff(&file, tmp.path(), "fn main() { println!(\"hi\"); }\n")
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
        let diff = git
            .text_diff(&file, tmp.path(), "pub fn x() {}\n")
            .await
            .unwrap();

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
        let diff = git
            .text_diff(&file, tmp.path(), "fn main() {}\n")
            .await
            .unwrap();

        assert!(diff.is_none());
    }

    #[tokio::test]
    async fn text_diff_returns_none_outside_repo() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("orphan.txt");
        tokio::fs::write(&file, "hello\n").await.unwrap();

        let git = GitService::new();
        let diff = git.text_diff(&file, tmp.path(), "hello\n").await.unwrap();

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
        let diff = git.text_diff(&file, tmp.path(), &lines).await.unwrap();

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
        let diff = git.text_diff(&file, tmp.path(), &new_lines).await.unwrap();

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
        let diff = git.text_diff(&file, tmp.path(), &body).await.unwrap();

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
        let diff = git
            .text_diff(&file, tmp.path(), "pub mod b;\n")
            .await
            .unwrap();

        assert!(diff.is_some());
        assert_eq!(diff.unwrap().old_text.as_deref(), Some("pub mod a;\n"));
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
