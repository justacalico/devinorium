//! Branch listing and manipulation.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use super::{GitError, GitService};
use super::runner::parse_track;

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

/// Validate a branch name without hitting the filesystem.
pub(super) fn is_safe_branch_name(name: &str) -> bool {
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

impl GitService {
    /// Return branches sorted by recency and name, with current and default
    /// branches promoted. When `force` is true, re-list branches from git.
    pub async fn branches(
        &self,
        path: &Path,
        query: Option<&str>,
        limit: Option<usize>,
        force: bool,
    ) -> Result<Vec<Branch>, GitError> {
        let status = self.repo_status(path, force).await?;
        if !status.is_repo {
            return Err(GitError::NotRepo);
        }
        let key = path.to_string_lossy().to_string();
        if force {
            self.branch_cache.invalidate(&key);
        }
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

    /// Create a new branch. If `switch` is true, check it out.
    pub async fn create_branch(
        &self,
        path: &Path,
        name: &str,
        base: Option<&str>,
        switch: bool,
    ) -> Result<String, GitError> {
        self.repo_status(path, false).await?;

        if !is_safe_branch_name(name) {
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
        self.repo_status(path, false).await?;

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
            .and_then(|s| {
                s.strip_prefix("refs/remotes/origin/")
                    .map(|s| s.trim().to_string())
            })
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

        Ok(parse_branches(&out, &current, &default))
    }
}

/// Parse `git for-each-ref` output into a sorted branch list.
pub(super) fn parse_branches(output: &str, current: &str, default: &str) -> Vec<Branch> {
    let mut branches = Vec::new();
    for line in output.lines() {
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
        let (ahead, behind) = parse_track(track);

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

    // Drop remote symbolic refs such as `origin/HEAD`; they are pointers,
    // not real branches, and would otherwise clutter the list.
    branches.retain(|b| !(b.is_remote && b.symref.is_some()));

    // Drop remote refs that have a local branch with the same short name
    // so `main` and `origin/main` do not show up as separate entries.
    // Remote branches are stored as `<remote>/<branch>`; strip the first
    // path component (the remote name) and keep the remote entry only when
    // no local counterpart exists.
    let local_names: HashSet<String> = branches
        .iter()
        .filter(|b| !b.is_remote)
        .map(|b| b.name.clone())
        .collect();
    branches.retain(|b| {
        if !b.is_remote {
            return true;
        }
        match b.name.split_once('/') {
            Some((_, short)) => !local_names.contains(short),
            None => true,
        }
    });

    branches.sort_by(|a, b| {
        let a_score = (a.is_current as i8) * 4 + (a.is_default as i8) * 2 - (a.is_remote as i8);
        let b_score = (b.is_current as i8) * 4 + (b.is_default as i8) * 2 - (b.is_remote as i8);
        b_score
            .cmp(&a_score)
            .then_with(|| b.committer_date.cmp(&a.committer_date))
            .then_with(|| a.name.cmp(&b.name))
    });

    branches
}

#[cfg(test)]
mod tests {
    use super::{is_safe_branch_name, parse_branches};

    #[test]
    fn is_safe_branch_name_rejects_dangerous_names() {
        assert!(is_safe_branch_name("feature"));
        assert!(is_safe_branch_name("feature/foo"));
        assert!(!is_safe_branch_name("../escape"));
        assert!(!is_safe_branch_name("/root"));
        assert!(!is_safe_branch_name(".."));
        assert!(!is_safe_branch_name(""));
    }

    #[test]
    fn parse_branches_sorts_and_filters() {
        let out = "refs/heads/main\t1000\t\t[ahead 1]\n\
                   refs/heads/feature\t900\t\t\n\
                   refs/remotes/origin/main\t950\tHEAD\t\n\
                   refs/remotes/origin/feature\t850\t\t";
        let branches = parse_branches(out, "main", "main");
        assert_eq!(branches.len(), 2);
        assert_eq!(branches[0].name, "main");
        assert!(branches[0].is_current);
        assert!(branches[0].is_default);
        assert_eq!(branches[1].name, "feature");
        assert!(!branches[1].is_remote);
    }
}
