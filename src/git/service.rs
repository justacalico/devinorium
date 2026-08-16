//! Git command execution, caching, and output parsing.

use std::path::{Path, PathBuf};
use std::time::Duration;

use regex::Regex;

use mini_moka::sync::Cache;
use tokio::process::Command;
use tokio::time::timeout;

/// Time-to-live for cached branch/ref snapshots.
const BRANCH_CACHE_TTL: Duration = Duration::from_secs(120);
/// TTL for repository detection and tracking counts.
const REPO_CACHE_TTL: Duration = Duration::from_secs(300);
/// Cache capacity to avoid memory bloat.
const CACHE_CAPACITY: u64 = 256;

/// Possible errors from Git operations.
#[derive(Debug, thiserror::Error)]
pub enum GitError {
    #[error("git support is not enabled on this backend")]
    NotEnabled,
    #[error("not a git repository")]
    NotRepo,
    #[error("timeout")]
    Timeout,
    #[error("{0}")]
    Other(String),
}

impl GitError {
    pub fn status_code(&self) -> axum::http::StatusCode {
        match self {
            GitError::NotEnabled | GitError::NotRepo => axum::http::StatusCode::NOT_FOUND,
            GitError::Timeout => axum::http::StatusCode::GATEWAY_TIMEOUT,
            GitError::Other(_) => axum::http::StatusCode::BAD_REQUEST,
        }
    }
}

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

/// A branch or remote ref.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Branch {
    pub name: String,
    pub refname: String,
    pub is_current: bool,
    pub is_default: bool,
    pub is_remote: bool,
    pub committer_date: i64,
    pub symref: Option<String>,
    pub ahead: i64,
    pub behind: i64,
}

/// A worktree.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Worktree {
    pub path: PathBuf,
    pub head: String,
    pub branch: Option<String>,
    pub is_main: bool,
}

/// Shared Git helper.
#[derive(Clone)]
pub struct GitService {
    git: Option<PathBuf>,
    repo_cache: Cache<String, RepoStatus>,
    branch_cache: Cache<String, Vec<Branch>>,
    worktree_cache: Cache<String, Vec<Worktree>>,
}

impl Default for GitService {
    fn default() -> Self {
        Self::new()
    }
}

impl GitService {
    /// Look up the `git` binary. If none is on PATH, all operations return
    /// `GitError::NotEnabled`.
    pub fn new() -> Self {
        let git = which::which("git").ok();
        Self {
            git,
            repo_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(REPO_CACHE_TTL)
                .build(),
            branch_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(BRANCH_CACHE_TTL)
                .build(),
            worktree_cache: Cache::builder()
                .max_capacity(CACHE_CAPACITY)
                .time_to_live(BRANCH_CACHE_TTL)
                .build(),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.git.is_some()
    }

    fn is_safe_branch_name(&self, name: &str) -> bool {
        if name.is_empty() || name.trim().is_empty() {
            return false;
        }
        if name.starts_with('/') || name.starts_with('~') {
            return false;
        }
        if name.contains("..") || name.contains('\0') {
            return false;
        }
        if name == "." || name == ".." {
            return false;
        }
        true
    }

    /// Worktree names are used as filesystem directory names, so we disallow
    /// path separators entirely to prevent traversal.
    fn is_safe_worktree_name(&self, name: &str) -> bool {
        if !self.is_safe_branch_name(name) {
            return false;
        }
        if name.contains('/') || name.contains('\\') {
            return false;
        }
        true
    }

    /// Return repository status for a project path.
    pub async fn repo_status(&self, path: &Path) -> Result<RepoStatus, GitError> {
        if self.git.is_none() {
            return Err(GitError::NotEnabled);
        }
        let key = path.to_string_lossy().to_string();
        if let Some(status) = self.repo_cache.get(&key) {
            return Ok(status);
        }

        let status = self.detect_repo(path).await?;
        self.repo_cache.insert(key.clone(), status.clone());
        // Tracking fetches remote refs, so clear the branch cache for this path.
        self.branch_cache.invalidate(&key);
        Ok(status)
    }

    /// Return branches sorted by recency and name, with current and default
    /// branches promoted.
    pub async fn branches(
        &self,
        path: &Path,
        query: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Vec<Branch>, GitError> {
        let status = self.repo_status(path).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let key = path.to_string_lossy().to_string();
        let mut branches = if let Some(b) = self.branch_cache.get(&key) {
            b
        } else {
            let b = self.list_branches(path).await?;
            self.branch_cache.insert(key, b.clone());
            b
        };

        if let Some(q) = query {
            branches = branches
                .into_iter()
                .filter(|b| b.name.to_lowercase().contains(&q.to_lowercase()))
                .collect();
        }

        if let Some(limit) = limit {
            branches.truncate(limit);
        }
        Ok(branches)
    }

    /// Return worktrees.
    pub async fn worktrees(&self, path: &Path) -> Result<Vec<Worktree>, GitError> {
        let status = self.repo_status(path).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let key = path.to_string_lossy().to_string();
        if let Some(worktrees) = self.worktree_cache.get(&key) {
            return Ok(worktrees);
        }
        let worktrees = self.list_worktrees(path).await?;
        self.worktree_cache.insert(key, worktrees.clone());
        Ok(worktrees)
    }

    /// Create a new branch. If `switch` is true, check it out.
    pub async fn create_branch(
        &self,
        path: &Path,
        name: &str,
        base: Option<&str>,
        switch: bool,
    ) -> Result<String, GitError> {
        self.repo_status(path).await?;

        if !self.is_safe_branch_name(name) {
            return Err(GitError::Other("invalid branch name".to_string()));
        }

        // Use git check-ref-format to reject branches that look like paths or
        // contain otherwise invalid characters.
        let mut check = self.git_cmd(path);
        check.arg("check-ref-format").arg("--branch").arg(name);
        if let Err(e) = self.run(&mut check, Duration::from_secs(5)).await {
            return Err(GitError::Other(format!("invalid branch name: {e}")));
        }

        let mut cmd = self.git_cmd(path);
        cmd.arg("branch").arg(name);
        if let Some(base) = base {
            if base.trim().is_empty() {
                return Err(GitError::Other("invalid base branch".to_string()));
            }
            cmd.arg(base);
        }
        self.run(&mut cmd, Duration::from_secs(5)).await?;

        if switch {
            self.checkout(path, name, false).await?;
        }

        self.invalidate(path);
        Ok(name.to_string())
    }

    /// Switch to an existing or remote branch.
    pub async fn checkout(
        &self,
        path: &Path,
        ref_name: &str,
        track: bool,
    ) -> Result<String, GitError> {
        self.repo_status(path).await?;

        if ref_name.trim().is_empty() {
            return Err(GitError::Other("ref name is required".to_string()));
        }

        let mut cmd = self.git_cmd(path);
        cmd.arg("checkout");
        if track {
            cmd.arg("--track");
        }
        cmd.arg(ref_name);
        self.run(&mut cmd, Duration::from_secs(10)).await?;

        self.invalidate(path);
        Ok(ref_name.to_string())
    }

    /// Create a worktree, optionally creating a new branch.
    pub async fn create_worktree(
        &self,
        path: &Path,
        name: &str,
        base: &str,
        new_branch: bool,
    ) -> Result<Worktree, GitError> {
        self.repo_status(path).await?;

        if !self.is_safe_worktree_name(name) {
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
        self.repo_status(path).await?;

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

    /// Run `git status --porcelain=2 --branch` and `git diff HEAD --numstat`
    /// to produce a compact status summary.
    pub async fn status(&self, path: &Path) -> Result<serde_json::Value, GitError> {
        self.repo_status(path).await?;

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

        Ok(serde_json::json!({
            "ahead": ahead,
            "behind": behind,
            "dirty_files": dirty,
            "changed_files": changed,
            "insertions": added,
            "deletions": deleted,
        }))
    }

    /// Pull the current branch's upstream using fast-forward only.
    pub async fn pull(&self, path: &Path) -> Result<(), GitError> {
        self.repo_status(path).await?;
        let mut cmd = self.git_cmd(path);
        cmd.arg("pull").arg("--ff-only");
        self.run(&mut cmd, Duration::from_secs(60)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Push the current branch to its remote, setting upstream if needed.
    pub async fn push(&self, path: &Path) -> Result<(), GitError> {
        let status = self.repo_status(path).await?;
        if status.branch.is_empty() || !self.is_safe_branch_name(&status.branch) {
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

        let remote = match tracked_remote {
            Some(r) => r,
            None => {
                let remotes = self
                    .run_with(path, &["remote"], Duration::from_secs(5))
                    .await?;
                let lines: Vec<&str> = remotes.lines().collect();
                if lines.is_empty() {
                    return Err(GitError::Other("no remote configured".to_string()));
                }
                lines
                    .iter()
                    .find(|&&r| r == "origin")
                    .copied()
                    .or(lines.first().copied())
                    .map(str::to_string)
                    .ok_or_else(|| GitError::Other("no remote configured".to_string()))?
            }
        };

        let mut cmd = self.git_cmd(path);
        cmd.arg("push").arg("-u").arg(remote).arg(&status.branch);
        self.run(&mut cmd, Duration::from_secs(60)).await?;
        self.invalidate(path);
        Ok(())
    }

    /// Fetch refs from the configured remote. Errors are ignored so stale
    /// tracking data does not block the UI.
    async fn fetch(&self, path: &Path) {
        if self.git.is_none() {
            return;
        }
        let mut cmd = self.git_cmd(path);
        cmd.arg("fetch");
        let _ = self.run(&mut cmd, Duration::from_secs(30)).await;
    }

    fn invalidate(&self, path: &Path) {
        let key = path.to_string_lossy().to_string();
        self.repo_cache.invalidate(&key);
        self.branch_cache.invalidate(&key);
        self.worktree_cache.invalidate(&key);
    }

    fn git_cmd(&self, cwd: &Path) -> Command {
        let mut cmd = Command::new(self.git.as_ref().expect("git enabled"));
        cmd.current_dir(cwd)
            .env("LC_ALL", "C")
            .env("GCM_INTERACTIVE", "never")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("SSH_ASKPASS_REQUIRE", "never");
        cmd
    }

    async fn run(&self, cmd: &mut Command, max: Duration) -> Result<String, GitError> {
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

    async fn run_with(&self, cwd: &Path, args: &[&str], max: Duration) -> Result<String, GitError> {
        let mut cmd = self.git_cmd(cwd);
        cmd.args(args);
        self.run(&mut cmd, max).await
    }

    async fn tracking(&self, path: &Path, branch: &str) -> Result<(i64, i64), GitError> {
        if branch.is_empty() || !self.is_safe_branch_name(branch) {
            return Ok((0, 0));
        }

        self.fetch(path).await;

        let upstream_arg = format!("{}@{{u}}", branch);
        let upstream = self
            .run_with(
                path,
                &["rev-parse", "--symbolic-full-name", &upstream_arg],
                Duration::from_secs(5),
            )
            .await
            .map(|s| s.trim().to_string())
            .ok()
            .filter(|s| !s.is_empty());

        let Some(upstream) = upstream else {
            return Ok((0, 0));
        };

        let ahead = self
            .run_with(
                path,
                &[
                    "rev-list",
                    "--count",
                    &format!("{}..{}", upstream, branch),
                ],
                Duration::from_secs(10),
            )
            .await
            .and_then(|s| s.trim().parse().map_err(|_| GitError::Other("invalid ahead count".to_string())))
            .unwrap_or(0);

        let behind = self
            .run_with(
                path,
                &[
                    "rev-list",
                    "--count",
                    &format!("{}..{}", branch, upstream),
                ],
                Duration::from_secs(10),
            )
            .await
            .and_then(|s| s.trim().parse().map_err(|_| GitError::Other("invalid behind count".to_string())))
            .unwrap_or(0);

        Ok((ahead, behind))
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

    async fn list_branches(&self, path: &Path) -> Result<Vec<Branch>, GitError> {
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

        let default = self
            .run_with(
                path,
                &["symbolic-ref", "refs/remotes/origin/HEAD"],
                Duration::from_secs(5),
            )
            .await
            .ok()
            .and_then(|s| s.strip_prefix("refs/remotes/origin/").map(str::to_string))
            .unwrap_or_else(|| current.clone());

        let out = self
            .run_with(
                path,
                &[
                    "for-each-ref",
                    "--format=%(refname)\t%(committerdate:unix)\t%(symref)\t%(upstream:track)",
                    "refs/heads",
                    "refs/remotes",
                ],
                Duration::from_secs(30),
            )
            .await?;

        let ahead_re = Regex::new(r"ahead\s+(\d+)").expect("valid regex");
        let behind_re = Regex::new(r"behind\s+(\d+)").expect("valid regex");

        let mut branches = Vec::new();
        for line in out.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() < 4 {
                continue;
            }
            let refname = parts[0];
            let date = parts[1].parse::<i64>().unwrap_or(0);
            let symref = parts.get(2).and_then(|s| {
                let s = *s;
                if s.is_empty() {
                    None
                } else {
                    Some(s.to_string())
                }
            });
            let track = parts.get(3).copied().unwrap_or("");

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

            let (name, is_remote, is_current, is_default) =
                if let Some(name) = refname.strip_prefix("refs/heads/") {
                    (name.to_string(), false, name == current, name == default)
                } else if let Some(name) = refname.strip_prefix("refs/remotes/") {
                    (name.to_string(), true, false, name == default)
                } else {
                    continue;
                };

            branches.push(Branch {
                name,
                refname: refname.to_string(),
                is_current,
                is_default,
                is_remote,
                committer_date: date,
                symref,
                ahead,
                behind,
            });
        }

        branches.sort_by(|a, b| {
            let a_score = (a.is_current as i8) * 4 + (a.is_default as i8) * 2 - (a.is_remote as i8);
            let b_score = (b.is_current as i8) * 4 + (b.is_default as i8) * 2 - (b.is_remote as i8);
            b_score
                .cmp(&a_score)
                .then_with(|| b.committer_date.cmp(&a.committer_date))
                .then_with(|| a.name.cmp(&b.name))
        });

        Ok(branches)
    }

    async fn list_worktrees(&self, path: &Path) -> Result<Vec<Worktree>, GitError> {
        let out = self
            .run_with(
                path,
                &["worktree", "list", "--porcelain", "-z"],
                Duration::from_secs(5),
            )
            .await?;

        let mut worktrees = Vec::new();
        let mut path_buf = None;
        let mut head = String::new();
        let mut branch = None;

        for token in out.split('\0') {
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

        Ok(worktrees)
    }
}
