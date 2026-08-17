//! Integration tests for Git branch and worktree support.

#![cfg(test)]

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use tempfile::TempDir;

use devinorium::git::{GitRemoteService, GitService};

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
    let status = svc.repo_status(tmp.path()).await.unwrap();
    assert!(!status.is_repo);
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

#[tokio::test]
async fn repo_status_includes_ahead_and_behind() {
    let local = make_repo();
    git_cli(&["checkout", "-b", "main"], local.path());

    let remote = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], remote.path());
    git_cli(
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
        local.path(),
    );
    git_cli(&["push", "-u", "origin", "main"], local.path());

    std::fs::write(local.path().join("file2.txt"), "hello2").unwrap();
    git_cli(&["add", "file2.txt"], local.path());
    git_cli(&["commit", "-m", "second"], local.path());

    let svc = GitService::new();
    let status = svc.repo_status(local.path()).await.unwrap();
    assert_eq!(status.branch, "main");
    assert_eq!(status.ahead, 1);
    assert_eq!(status.behind, 0);

    let branches = svc.branches(local.path(), None, None).await.unwrap();
    let main = branches.iter().find(|b| b.name == "main").unwrap();
    assert_eq!(main.ahead, 1);
    assert_eq!(main.behind, 0);

    svc.push(local.path()).await.unwrap();
    let status = svc.repo_status(local.path()).await.unwrap();
    assert_eq!(status.ahead, 0);
    assert_eq!(status.behind, 0);
}

#[tokio::test]
async fn pull_fast_forwards_behind_commits() {
    let local = make_repo();
    git_cli(&["checkout", "-b", "main"], local.path());

    let remote = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], remote.path());
    git_cli(
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
        local.path(),
    );
    git_cli(&["push", "-u", "origin", "main"], local.path());

    let other = TempDir::new().unwrap();
    git_cli(
        &["clone", remote.path().to_str().unwrap(), "."],
        other.path(),
    );
    git_cli(
        &["checkout", "-b", "main", "origin/main"],
        other.path(),
    );
    std::fs::write(other.path().join("file2.txt"), "from other").unwrap();
    git_cli(&["add", "file2.txt"], other.path());
    git_cli(&["commit", "-m", "remote commit"], other.path());
    git_cli(&["push", "-u", "origin", "main"], other.path());

    let svc = GitService::new();
    let status = svc.repo_status(local.path()).await.unwrap();
    assert_eq!(status.branch, "main");
    assert_eq!(status.behind, 1);
    assert_eq!(status.ahead, 0);

    svc.pull(local.path()).await.unwrap();
    let status = svc.repo_status(local.path()).await.unwrap();
    assert_eq!(status.behind, 0);
    assert_eq!(status.ahead, 0);
    assert!(local.path().join("file2.txt").exists());
}

#[tokio::test]
async fn pulls_non_current_branch_without_checking_out() {
    let local = make_repo();
    git_cli(&["checkout", "-b", "main"], local.path());

    let remote = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], remote.path());
    git_cli(
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
        local.path(),
    );
    git_cli(&["push", "-u", "origin", "main"], local.path());

    let other = TempDir::new().unwrap();
    git_cli(
        &["clone", remote.path().to_str().unwrap(), "."],
        other.path(),
    );
    git_cli(&["checkout", "-b", "feature"], other.path());
    std::fs::write(other.path().join("file2.txt"), "from other").unwrap();
    git_cli(&["add", "file2.txt"], other.path());
    git_cli(&["commit", "-m", "feature commit"], other.path());
    git_cli(&["push", "-u", "origin", "feature"], other.path());

    git_cli(&["fetch", "origin", "feature"], local.path());
    git_cli(&["branch", "feature", "main"], local.path());
    git_cli(
        &["branch", "--set-upstream-to=origin/feature", "feature"],
        local.path(),
    );

    let svc = GitService::new();

    let branches = svc.branches(local.path(), None, None).await.unwrap();
    let feature = branches.iter().find(|b| b.name == "feature").unwrap();
    assert_eq!(feature.behind, 1);

    svc.pull_branch(local.path(), "feature").await.unwrap();

    let origin_feature = Command::new("git")
        .args(["rev-parse", "origin/feature"])
        .current_dir(local.path())
        .output()
        .unwrap();
    let local_feature = Command::new("git")
        .args(["rev-parse", "feature"])
        .current_dir(local.path())
        .output()
        .unwrap();
    assert_eq!(origin_feature.stdout, local_feature.stdout);

    let head = Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .current_dir(local.path())
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&head.stdout).trim(), "main");
    assert!(!local.path().join("file2.txt").exists());
}

fn write_fake_glab(dir: &Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
set -e
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
  if [ "$3" = "token" ]; then
    mkdir -p "$XDG_CONFIG_HOME"
    printf '%s' "$4" > "$XDG_CONFIG_HOME/token"
  fi
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  if [ -f "$XDG_CONFIG_HOME/token" ] && [ -s "$XDG_CONFIG_HOME/token" ]; then
    echo "$host"
    echo "  Logged in to $host as testuser"
    exit 0
  else
    echo "$host"
    echo "  ! No token found"
    exit 1
  fi
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then
  rm -f "$XDG_CONFIG_HOME/token"
  echo "Successfully logged out"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_remote_connection_list_reflects_glab_status() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let list = svc.connections(1).await;
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].id, "gitlab");
    assert!(!list[0].authed);
    assert_eq!(list[1].id, "github");
    assert!(list[1].coming_soon);
}

#[tokio::test]
async fn git_remote_gitlab_login_and_logout() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let status = svc.login_gitlab(1, "glpat-test-token", None).await.unwrap();
    assert!(status.authed);
    assert_eq!(status.account.as_deref(), Some("testuser"));
    assert_eq!(status.host, "gitlab.com");

    let after_login = svc.connections(1).await;
    assert!(after_login[0].authed);

    svc.logout_gitlab(1, None).await.unwrap();

    let after_logout = svc.connections(1).await;
    assert!(!after_logout[0].authed);
}

#[tokio::test]
async fn git_remote_gitlab_login_uses_custom_host() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let status = svc
        .login_gitlab(1, "glpat-test-token", Some("gitlab.example.com"))
        .await
        .unwrap();
    assert_eq!(status.host, "gitlab.example.com");
    assert!(status.authed);
}

fn write_garbage_glab(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    std::fs::write(&bin, "#!/bin/sh\necho 'garbage output'\nexit 1\n").unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_remote_gitlab_status_fails_on_unparseable_output() {
    let tmp = TempDir::new().unwrap();
    let glab = write_garbage_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let err = svc.gitlab_status(1).await.unwrap_err();
    assert!(matches!(err, devinorium::git::RemoteError::StatusFailed(_)));
}
