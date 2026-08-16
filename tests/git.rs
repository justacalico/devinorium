//! Integration tests for Git branch and worktree support.

#![cfg(test)]

use std::path::Path;
use std::process::Command;

use tempfile::TempDir;

use devinorium::git::GitService;

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
    std::fs::write(tmp.path().join("file.txt"), "hello").unwrap();
    git_cli(&["add", "file.txt"], tmp.path());
    git_cli(&["commit", "-m", "initial"], tmp.path());
    tmp
}

#[tokio::test]
async fn detects_git_repository() {
    let tmp = make_repo();
    let svc = GitService::new();
    let status = svc.repo_status(tmp.path()).await.unwrap();
    assert!(status.is_repo);
    assert!(!status.branch.is_empty());
}

#[tokio::test]
async fn non_repo_returns_not_repo() {
    let tmp = TempDir::new().unwrap();
    let svc = GitService::new();
    let err = svc.repo_status(tmp.path()).await.unwrap_err();
    assert!(matches!(err, devinorium::git::GitError::NotRepo));
}

#[tokio::test]
async fn lists_branches_sorted_by_current_first() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "feature-1"], tmp.path());
    git_cli(&["checkout", "-b", "feature-2"], tmp.path());

    let svc = GitService::new();
    let branches = svc.branches(tmp.path(), None, None).await.unwrap();

    assert!(!branches.is_empty());
    let current = branches.iter().find(|b| b.is_current).map(|b| &b.name);
    assert_eq!(current, Some(&"feature-2".to_string()));
    assert!(branches[0].is_current);
}

#[tokio::test]
async fn filters_branches_by_query() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "feature-a"], tmp.path());
    git_cli(&["checkout", "-b", "feature-b"], tmp.path());

    let svc = GitService::new();
    let branches = svc
        .branches(tmp.path(), Some("feature-a"), None)
        .await
        .unwrap();
    assert_eq!(branches.len(), 1);
    assert_eq!(branches[0].name, "feature-a");
}

#[tokio::test]
async fn creates_branch_without_switch() {
    let tmp = make_repo();
    let svc = GitService::new();
    let name = svc
        .create_branch(tmp.path(), "new-branch", None, false)
        .await
        .unwrap();
    assert_eq!(name, "new-branch");

    let out = Command::new("git")
        .args(["rev-parse", "--verify", "new-branch"])
        .current_dir(tmp.path())
        .output()
        .unwrap();
    assert!(out.status.success());
}

#[tokio::test]
async fn creates_and_switches_branch() {
    let tmp = make_repo();
    let svc = GitService::new();
    svc.create_branch(tmp.path(), "switched", None, true)
        .await
        .unwrap();
    let head = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(tmp.path())
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&head.stdout).trim(), "switched");
}

#[tokio::test]
async fn rejects_path_traversal_in_worktree_name() {
    let tmp = make_repo();
    let svc = GitService::new();
    let err = svc
        .create_worktree(tmp.path(), "../escape", "HEAD", false)
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::GitError::Other(_)));
    assert!(!tmp.path().parent().unwrap().join("escape").exists());
}

#[tokio::test]
async fn rejects_invalid_branch_name() {
    let tmp = make_repo();
    let svc = GitService::new();
    let err = svc
        .create_branch(tmp.path(), "../bad", None, false)
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::GitError::Other(_)));
}

#[tokio::test]
async fn cannot_remove_main_worktree() {
    let tmp = make_repo();
    let svc = GitService::new();
    let err = svc
        .remove_worktree(tmp.path(), tmp.path())
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::GitError::Other(_)));
}

#[tokio::test]
async fn cannot_remove_unknown_worktree() {
    let tmp = make_repo();
    let svc = GitService::new();
    let err = svc
        .remove_worktree(tmp.path(), Path::new("/tmp/nowhere"))
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::GitError::Other(_)));
}

#[tokio::test]
async fn worktree_create_and_remove() {
    let tmp = make_repo();
    let svc = GitService::new();
    let wt = svc
        .create_worktree(tmp.path(), "wt1", "HEAD", true)
        .await
        .unwrap();
    assert!(wt.path.exists());

    let worktrees = svc.worktrees(tmp.path()).await.unwrap();
    assert!(worktrees.iter().any(|w| w.path == wt.path));

    svc.remove_worktree(tmp.path(), &wt.path).await.unwrap();
    let worktrees = svc.worktrees(tmp.path()).await.unwrap();
    assert!(!worktrees.iter().any(|w| w.path == wt.path));
}
