//! Commit history for the git panel's history section.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;

use super::{GitError, GitService};

/// A single commit in `git log` output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CommitEntry {
    pub sha: String,
    pub subject: String,
    pub body: String,
    pub author: String,
    pub email: String,
    /// Unix committer timestamp, seconds.
    pub timestamp: i64,
    /// Decoration list (`HEAD -> main, origin/main`) or empty.
    pub refs: String,
}

/// One page of history plus whether more commits exist past it.
#[derive(Debug, Serialize)]
pub struct CommitPage {
    pub commits: Vec<CommitEntry>,
    pub has_more: bool,
}

impl GitService {
    /// Read `limit` commits starting at `offset`, newest first.
    ///
    /// One extra commit is fetched so `has_more` reflects reality without a
    /// second `git rev-list --count` call. A repository with no commits yet
    /// returns an empty page rather than an error.
    pub async fn log(
        &self,
        path: &Path,
        limit: usize,
        offset: usize,
        force: bool,
    ) -> Result<CommitPage, GitError> {
        let status = self.repo_status(path, force).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        // Unborn HEAD: `git log` would fail, but an empty history is a
        // normal state for a fresh repo.
        let head_exists = self
            .run_with(
                &status.toplevel,
                &["rev-parse", "--verify", "-q", "HEAD"],
                Duration::from_secs(5),
            )
            .await
            .is_ok();
        if !head_exists {
            return Ok(CommitPage {
                commits: Vec::new(),
                has_more: false,
            });
        }

        // `rev-list` gives the authoritative commit order and the
        // `has_more` signal; commit contents are then read per sha.
        // Parsing one `git log` stream instead would let a `\x1f` or NUL
        // inside a crafted commit body shift fields or fabricate a record
        // that never existed.
        let revs = self
            .run_with(
                &status.toplevel,
                &[
                    "rev-list",
                    &format!("--max-count={}", limit.saturating_add(1)),
                    &format!("--skip={offset}"),
                    "HEAD",
                ],
                Duration::from_secs(10),
            )
            .await?;
        let shas: Vec<&str> = revs
            .lines()
            .filter(|l| l.len() == 40 && l.bytes().all(|b| b.is_ascii_hexdigit()))
            .collect();
        let has_more = shas.len() > limit;

        let mut commits = Vec::new();
        for sha in shas.iter().take(limit) {
            let out = self
                .run_with(
                    &status.toplevel,
                    &[
                        "show",
                        "-s",
                        "--format=%s%x1f%an%x1f%ae%x1f%ct%x1f%D%x1f%b",
                        sha,
                    ],
                    Duration::from_secs(5),
                )
                .await?;
            if let Some(c) = parse_commit(sha, &out) {
                commits.push(c);
            }
        }
        Ok(CommitPage { commits, has_more })
    }
}

/// Parse one commit's `git show -s` output: `\x1f` separates the format
/// fields. `%b` comes last so a `\x1f` inside the body just rejoins; a
/// record that fails validation — a short field list, an unparsable
/// timestamp — is skipped rather than emitted with shifted fields.
fn parse_commit(sha: &str, output: &str) -> Option<CommitEntry> {
    let mut f = output.trim_matches('\n').split('\x1f');
    let subject = f.next()?.to_string();
    let author = f.next()?.to_string();
    let email = f.next()?.to_string();
    let timestamp = f.next()?.parse().ok()?;
    let refs = f.next()?.to_string();
    let body = f.collect::<Vec<_>>().join("\x1f").trim().to_string();
    Some(CommitEntry {
        sha: sha.to_string(),
        subject,
        body,
        author,
        email,
        timestamp,
        refs,
    })
}

#[cfg(test)]
mod tests {
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
        tmp
    }

    fn commit_file(dir: &Path, name: &str, content: &str, message: &str) {
        std::fs::write(dir.join(name), content).unwrap();
        git_cli(&["add", name], dir);
        git_cli(&["commit", "-m", message], dir);
    }

    #[tokio::test]
    async fn log_lists_commits_newest_first() {
        let tmp = make_repo();
        commit_file(tmp.path(), "a.txt", "a", "first\n\nbody text");
        commit_file(tmp.path(), "b.txt", "b", "second");

        let svc = GitService::new();
        let page = svc.log(tmp.path(), 30, 0, false).await.unwrap();

        assert_eq!(page.commits.len(), 2);
        assert!(!page.has_more);
        assert_eq!(page.commits[0].subject, "second");
        assert_eq!(page.commits[1].subject, "first");
        assert_eq!(page.commits[1].body, "body text");
        assert_eq!(page.commits[0].author, "Test");
        assert_eq!(page.commits[0].email, "test@example.com");
        assert!(page.commits[0].timestamp > 0);
        assert_eq!(page.commits[0].sha.len(), 40);
        assert!(page.commits[0].refs.contains("HEAD"));
    }

    #[tokio::test]
    async fn log_paginates_with_skip() {
        let tmp = make_repo();
        for i in 0..5 {
            commit_file(tmp.path(), &format!("f{i}.txt"), "x", &format!("c{i}"));
        }

        let svc = GitService::new();
        let page1 = svc.log(tmp.path(), 2, 0, false).await.unwrap();
        assert!(page1.has_more);
        assert_eq!(page1.commits.len(), 2);
        assert_eq!(page1.commits[0].subject, "c4");

        let page2 = svc.log(tmp.path(), 2, 2, false).await.unwrap();
        assert!(page2.has_more);
        assert_eq!(page2.commits[0].subject, "c2");

        let page3 = svc.log(tmp.path(), 2, 4, false).await.unwrap();
        assert!(!page3.has_more);
        assert_eq!(page3.commits.len(), 1);
        assert_eq!(page3.commits[0].subject, "c0");
    }

    #[tokio::test]
    async fn log_empty_repo_returns_empty_page() {
        let tmp = make_repo();
        let svc = GitService::new();
        let page = svc.log(tmp.path(), 30, 0, false).await.unwrap();
        assert!(page.commits.is_empty());
        assert!(!page.has_more);
    }

    #[tokio::test]
    async fn log_non_repo_errors() {
        let tmp = TempDir::new().unwrap();
        let svc = GitService::new();
        let err = svc.log(tmp.path(), 30, 0, false).await.unwrap_err();
        assert!(matches!(err, super::GitError::NotRepo));
    }

    #[test]
    fn parse_commit_skips_malformed_records() {
        let sha = "a".repeat(40);
        // A \x1f inside the subject shifts every field; the record must be
        // dropped instead of producing a garbage timestamp or author.
        let shifted = "sub\x1fject\x1fAuthor\x1fa@b.c\x1f1700000000\x1f\x1fbody";
        assert!(super::parse_commit(&sha, shifted).is_none());
        assert!(super::parse_commit(&sha, "garbage-no-fields").is_none());
        let good = "subject\x1fAuthor\x1fa@b.c\x1f1700000000\x1fHEAD -> main\x1fbody";
        let c = super::parse_commit(&sha, good).unwrap();
        assert_eq!(c.subject, "subject");
        assert_eq!(c.body, "body");
        assert_eq!(c.timestamp, 1700000000);
        assert_eq!(c.sha, sha);
    }

    #[test]
    fn parse_commit_rejoins_body_separator() {
        let sha = "a".repeat(40);
        let out = "sub\x1fA\x1fe\x1f1\x1f\x1fline1\x1fline2\n";
        let c = super::parse_commit(&sha, out).unwrap();
        assert_eq!(c.body, "line1\x1fline2");
    }

    #[tokio::test]
    async fn log_multiline_body_survives_parsing() {
        let tmp = make_repo();
        std::fs::write(tmp.path().join("a.txt"), "a").unwrap();
        git_cli(&["add", "a.txt"], tmp.path());
        git_cli(
            &[
                "commit",
                "-m",
                "subject line",
                "-m",
                "body\n\nwith paragraphs",
            ],
            tmp.path(),
        );

        let svc = GitService::new();
        let page = svc.log(tmp.path(), 30, 0, false).await.unwrap();
        assert_eq!(page.commits[0].subject, "subject line");
        assert_eq!(page.commits[0].body, "body\n\nwith paragraphs");
    }
}
