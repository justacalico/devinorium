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
    let status = svc.repo_status(tmp.path(), false).await.unwrap();
    assert!(status.is_repo);
    assert!(!status.branch.is_empty());
}

#[tokio::test]
async fn repo_status_force_refreshes_after_external_branch_switch() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "main"], tmp.path());
    let svc = GitService::new();

    let status = svc.repo_status(tmp.path(), false).await.unwrap();
    assert_eq!(status.branch, "main");

    // Switch branch outside the service (e.g. an AI agent).
    git_cli(&["checkout", "-b", "ai-switch"], tmp.path());

    // Cached status still reports the old branch.
    let cached = svc.repo_status(tmp.path(), false).await.unwrap();
    assert_eq!(cached.branch, "main");

    // Forced status picks up the new branch.
    let forced = svc.repo_status(tmp.path(), true).await.unwrap();
    assert_eq!(forced.branch, "ai-switch");
}

#[tokio::test]
async fn branches_force_refreshes_after_external_branch_switch() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "main"], tmp.path());
    let svc = GitService::new();

    let branches = svc.branches(tmp.path(), None, None, false).await.unwrap();
    let current = branches.iter().find(|b| b.is_current).map(|b| &b.name);
    assert_eq!(current, Some(&"main".to_string()));

    git_cli(&["checkout", "-b", "ai-switch"], tmp.path());

    // Forced branch list reflects the new current branch.
    let forced = svc.branches(tmp.path(), None, None, true).await.unwrap();
    let current = forced.iter().find(|b| b.is_current).map(|b| &b.name);
    assert_eq!(current, Some(&"ai-switch".to_string()));
}

#[tokio::test]
async fn non_repo_returns_not_repo() {
    let tmp = TempDir::new().unwrap();
    let svc = GitService::new();
    let status = svc.repo_status(tmp.path(), false).await.unwrap();
    assert!(!status.is_repo);
}

#[tokio::test]
async fn lists_branches_sorted_by_current_first() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "feature-1"], tmp.path());
    git_cli(&["checkout", "-b", "feature-2"], tmp.path());

    let svc = GitService::new();
    let branches = svc.branches(tmp.path(), None, None, false).await.unwrap();

    assert!(!branches.is_empty());
    let current = branches.iter().find(|b| b.is_current).map(|b| &b.name);
    assert_eq!(current, Some(&"feature-2".to_string()));
    assert!(branches[0].is_current);
}

#[tokio::test]
async fn lists_branches_marks_default_from_origin_head() {
    let tmp = make_repo();
    git_cli(&["branch", "-M", "main"], tmp.path());
    git_cli(&["checkout", "-b", "feature"], tmp.path());

    let origin = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], origin.path());
    let origin_url = origin.path().to_str().unwrap();
    git_cli(&["remote", "add", "origin", origin_url], tmp.path());
    git_cli(&["push", "origin", "main"], tmp.path());
    git_cli(&["symbolic-ref", "HEAD", "refs/heads/main"], origin.path());
    git_cli(&["remote", "set-head", "origin", "-a"], tmp.path());

    let svc = GitService::new();
    let branches = svc.branches(tmp.path(), None, None, false).await.unwrap();

    let current = branches.iter().find(|b| b.is_current).unwrap();
    assert_eq!(current.name, "feature");

    let default = branches.iter().find(|b| b.is_default).unwrap();
    assert_eq!(default.name, "main");
}

#[tokio::test]
async fn filters_branches_by_query() {
    let tmp = make_repo();
    git_cli(&["checkout", "-b", "feature-a"], tmp.path());
    git_cli(&["checkout", "-b", "feature-b"], tmp.path());

    let svc = GitService::new();
    let branches = svc
        .branches(tmp.path(), Some("feature-a"), None, false)
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

    let worktrees = svc.worktrees(tmp.path(), false).await.unwrap();
    assert!(worktrees.iter().any(|w| w.path == wt.path));

    svc.remove_worktree(tmp.path(), &wt.path).await.unwrap();
    let worktrees = svc.worktrees(tmp.path(), false).await.unwrap();
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
    let status = svc.repo_status(local.path(), false).await.unwrap();
    assert_eq!(status.branch, "main");
    assert_eq!(status.ahead, 1);
    assert_eq!(status.behind, 0);

    let branches = svc.branches(local.path(), None, None, false).await.unwrap();
    let main = branches.iter().find(|b| b.name == "main").unwrap();
    assert_eq!(main.ahead, 1);
    assert_eq!(main.behind, 0);

    svc.push(local.path()).await.unwrap();
    let status = svc.repo_status(local.path(), false).await.unwrap();
    assert_eq!(status.ahead, 0);
    assert_eq!(status.behind, 0);
}

#[tokio::test]
async fn list_branches_dedupes_local_and_remote_with_same_name() {
    let local = make_repo();
    git_cli(&["checkout", "-b", "main"], local.path());

    let remote = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], remote.path());
    git_cli(
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
        local.path(),
    );
    git_cli(&["push", "-u", "origin", "main"], local.path());

    // Create a remote-only branch with no local counterpart so it should
    // still appear in the list.
    let other = TempDir::new().unwrap();
    git_cli(
        &["clone", remote.path().to_str().unwrap(), "."],
        other.path(),
    );
    git_cli(&["checkout", "-b", "feature", "origin/main"], other.path());
    std::fs::write(other.path().join("f.txt"), "x").unwrap();
    git_cli(&["add", "f.txt"], other.path());
    git_cli(&["commit", "-m", "feature"], other.path());
    git_cli(&["push", "-u", "origin", "feature"], other.path());
    git_cli(&["fetch", "origin"], local.path());

    let svc = GitService::new();
    let branches = svc.branches(local.path(), None, None, false).await.unwrap();

    // `main` exists both locally and as `origin/main`; only one entry.
    let main_entries = branches.iter().filter(|b| b.name == "main").count();
    assert_eq!(main_entries, 1);
    // No `origin/main` entry should leak through.
    assert!(branches.iter().all(|b| b.name != "origin/main"));

    // `feature` has no local branch, so the remote ref is kept.
    let feature = branches.iter().find(|b| b.name == "origin/feature");
    assert!(feature.is_some(), "remote-only branch should be listed");
    assert!(feature.unwrap().is_remote);

    // `origin/HEAD` is a symbolic ref, not a real branch, and must not appear.
    assert!(branches.iter().all(|b| b.name != "origin/HEAD"));
}

#[tokio::test]
async fn list_branches_dedupes_slashed_branch_name() {
    let local = make_repo();
    git_cli(&["checkout", "-b", "main"], local.path());

    let remote = TempDir::new().unwrap();
    git_cli(&["init", "--bare"], remote.path());
    git_cli(
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
        local.path(),
    );
    git_cli(&["push", "-u", "origin", "main"], local.path());

    // Create a slashed branch both locally and on the remote.
    git_cli(&["checkout", "-b", "feature/foo", "main"], local.path());
    git_cli(&["push", "-u", "origin", "feature/foo"], local.path());
    git_cli(&["checkout", "main"], local.path());
    git_cli(&["fetch", "origin"], local.path());

    let svc = GitService::new();
    let branches = svc.branches(local.path(), None, None, false).await.unwrap();

    // Only one entry for `feature/foo`; no `origin/feature/foo` duplicate.
    let foo_entries = branches.iter().filter(|b| b.name == "feature/foo").count();
    assert_eq!(foo_entries, 1);
    assert!(branches.iter().all(|b| b.name != "origin/feature/foo"));
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
    git_cli(&["fetch", "origin"], local.path());

    let svc = GitService::new();
    let status = svc.repo_status(local.path(), false).await.unwrap();
    assert_eq!(status.branch, "main");
    assert_eq!(status.behind, 1);
    assert_eq!(status.ahead, 0);

    svc.pull(local.path()).await.unwrap();
    let status = svc.repo_status(local.path(), false).await.unwrap();
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
    git_cli(
        &["checkout", "-b", "feature", "origin/main"],
        other.path(),
    );
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

    let branches = svc.branches(local.path(), None, None, false).await.unwrap();
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
if [ "$1" = "api" ]; then
  path="$2"
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  printf '{"host":"%s","path":"%s"}\n' "$host" "$path"
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
    let svc = GitRemoteService::with_glab_bin(config_root.clone(), Some(glab));

    // Simulate a pre-authenticated glab CLI by writing the token it expects.
    let token_file = config_root.join("glab").join("1").join(".config").join("token");
    std::fs::create_dir_all(token_file.parent().unwrap()).unwrap();
    std::fs::write(&token_file, "glpat-test-token").unwrap();

    let status = svc.login_gitlab(1, None).await.unwrap();
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
    let svc = GitRemoteService::with_glab_bin(config_root.clone(), Some(glab));

    let token_file = config_root.join("glab").join("1").join(".config").join("token");
    std::fs::create_dir_all(token_file.parent().unwrap()).unwrap();
    std::fs::write(&token_file, "glpat-test-token").unwrap();

    let status = svc
        .login_gitlab(1, Some("gitlab.example.com"))
        .await
        .unwrap();
    assert_eq!(status.host, "gitlab.example.com");
    assert!(status.authed);
}

fn write_fake_glab_with_pipelines(dir: &std::path::Path) -> std::path::PathBuf {
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
if [ "$1" = "api" ]; then
  path="$2"
  case "$path" in
    *"/pipelines"*)
      if echo "$path" | grep -q "empty"; then
        printf '[]\n'
      else
        printf '[{"id":42,"status":"success","name":"test-and-build","web_url":"https://gitlab.example.com/group/project/-/pipelines/42","ref":"feature"}]\n'
      fi
      exit 0
      ;;
  esac
  printf '{"host":"%s","path":"%s"}\n' "$host" "$path"
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
async fn git_remote_gitlab_api_forwards_path_and_host() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let out = svc
        .gitlab_api(1, "gitlab.example.com", "projects/group%2Fproject/merge_requests/1")
        .await
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["host"], "gitlab.example.com");
    assert_eq!(v["path"], "projects/group%2Fproject/merge_requests/1");
}

#[tokio::test]
async fn git_remote_gitlab_api_rejects_non_project_paths() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let err = svc
        .gitlab_api(1, "gitlab.com", "groups/some-group")
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::RemoteError::StatusFailed(_)));
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_parses_and_sorts_list() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab_with_pipelines(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let pipelines = svc
        .gitlab_pipelines(1, "gitlab.example.com", "group/project", 1)
        .await
        .unwrap();

    assert_eq!(pipelines.len(), 1);
    let pipeline = &pipelines[0];
    assert_eq!(pipeline.status, "success");
    assert_eq!(pipeline.name, "test-and-build");
    assert_eq!(
        pipeline.web_url,
        "https://gitlab.example.com/group/project/-/pipelines/42"
    );
    assert_eq!(pipeline.ref_name, "feature");
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_returns_empty_list_when_none() {
    let tmp = TempDir::new().unwrap();
    let glab = write_fake_glab_with_pipelines(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let pipelines = svc
        .gitlab_pipelines(1, "gitlab.example.com", "empty/project", 1)
        .await
        .unwrap();

    assert!(pipelines.is_empty());
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_falls_back_to_unknown_status() {
    let tmp = TempDir::new().unwrap();
    let bin_dir = tmp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
if [ "$1" = "api" ]; then
  printf '[{"id":7,"web_url":"https://gitlab.example.com/-/pipelines/7","ref":"feature"}]\n'
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();

    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(bin));

    let pipelines = svc
        .gitlab_pipelines(1, "gitlab.example.com", "group/project", 1)
        .await
        .unwrap();

    assert_eq!(pipelines.len(), 1);
    assert_eq!(pipelines[0].status, "unknown");
    assert_eq!(pipelines[0].name, "feature");
    assert_eq!(pipelines[0].web_url, "https://gitlab.example.com/-/pipelines/7");
    assert_eq!(pipelines[0].ref_name, "feature");
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_sorts_by_updated_at_descending() {
    let tmp = TempDir::new().unwrap();
    let bin_dir = tmp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
if [ "$1" = "api" ]; then
  printf '[{"id":1,"status":"success","updated_at":"2026-01-02T00:00:00Z","ref":"old"},{"id":2,"status":"failed","updated_at":"2026-01-03T00:00:00Z","ref":"new"}]\n'
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();

    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(bin));

    let pipelines = svc
        .gitlab_pipelines(1, "gitlab.example.com", "group/project", 1)
        .await
        .unwrap();

    assert_eq!(pipelines.len(), 2);
    assert_eq!(pipelines[0].status, "failed");
    assert_eq!(pipelines[0].ref_name, "new");
    assert_eq!(pipelines[1].status, "success");
    assert_eq!(pipelines[1].ref_name, "old");
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_sorts_missing_timestamp_to_bottom() {
    let tmp = TempDir::new().unwrap();
    let bin_dir = tmp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
if [ "$1" = "api" ]; then
  printf '[{"id":1,"status":"failed","ref":"missing-timestamp"},{"id":2,"status":"success","updated_at":"2026-01-02T00:00:00Z","ref":"has-timestamp"}]\n'
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();

    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(bin));

    let pipelines = svc
        .gitlab_pipelines(1, "gitlab.example.com", "group/project", 1)
        .await
        .unwrap();

    assert_eq!(pipelines.len(), 2);
    assert_eq!(pipelines[0].ref_name, "has-timestamp");
    assert_eq!(pipelines[1].ref_name, "missing-timestamp");
}

#[tokio::test]
async fn git_remote_gitlab_pipelines_rejects_invalid_json() {
    let tmp = TempDir::new().unwrap();
    let glab = write_garbage_glab(tmp.path());
    let config_root = tmp.path().join("config");
    std::fs::create_dir_all(&config_root).unwrap();
    let svc = GitRemoteService::with_glab_bin(config_root, Some(glab));

    let err = svc
        .gitlab_pipelines(1, "gitlab.com", "group/project", 1)
        .await
        .unwrap_err();
    assert!(matches!(err, devinorium::git::RemoteError::StatusFailed(_)));
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
