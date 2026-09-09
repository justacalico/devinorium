//! Auto worktree creation for threads.

use crate::db::{ThreadRow, UserRow};
use crate::git::service::worktree as wt;
use crate::git::GitError;
use crate::AppState;

/// If the thread is in worktree mode and has no worktree yet, create one
/// under the project's managed worktree directory and persist it to the
/// thread row.
///
/// Returns `Ok(())` and leaves the thread unchanged when no worktree is
/// needed, the project is not a git repo, or the repo has no current branch.
/// Returns an error when a worktree is needed but cannot be created.
pub(crate) async fn ensure_thread_worktree(
    state: &AppState,
    user: &UserRow,
    thread: &mut ThreadRow,
) -> anyhow::Result<()> {
    if thread.env_mode != "worktree" {
        return Ok(());
    }
    if let Some(path) = &thread.worktree_path {
        if !path.is_empty() {
            return Ok(());
        }
    }

    // Serialize per-thread so concurrent first sends race on the same worktree
    // rather than creating duplicates.
    let lock = state.git.worktree_creation_lock(&thread.id).await;
    let _guard = lock.lock().await;

    // Another request may have won the race while we waited; refresh from DB.
    if let Some(fresh) = state.db.get_thread(&thread.id, user.id).await? {
        if let Some(path) = &fresh.worktree_path {
            if !path.is_empty() {
                *thread = fresh;
                return Ok(());
            }
        }
    }

    let Some(project_id) = thread.project_id else {
        anyhow::bail!("worktree mode requires a project");
    };
    let project = match state.db.get_project(project_id, user.id).await? {
        Some(p) => p,
        None => anyhow::bail!("project not found"),
    };
    let project_path = std::path::PathBuf::from(&project.path);

    let status = match state.git.repo_status(&project_path, true).await {
        Ok(s) if s.is_repo => s,
        _ => return Ok(()),
    };

    let base = if status.branch.is_empty() {
        "HEAD".to_string()
    } else {
        status.branch
    };

    let mut attempts = 0;
    let worktree = loop {
        let branch = wt::temporary_worktree_branch_name();
        let worktree_path = wt::managed_worktree_path(&status.toplevel, &branch);

        match state
            .git
            .create_worktree_at(&status.toplevel, &branch, &base, &worktree_path, true)
            .await
        {
            Ok(w) => break (branch, w),
            Err(GitError::Other(msg)) if msg.contains("already exists") && attempts < 5 => {
                attempts += 1;
                continue;
            }
            Err(e) => anyhow::bail!("failed to create worktree: {e}"),
        }
    };

    let branch = worktree.0;
    let worktree_path = worktree.1.path.to_string_lossy().to_string();

    state
        .db
        .update_thread_git(&thread.id, user.id, Some(&branch), Some(&worktree_path))
        .await?;

    // Refresh the worktree list under the project path so the UI picks it up.
    let _ = state.git.worktrees(&project_path, true).await;

    thread.branch = Some(branch);
    thread.worktree_path = Some(worktree_path);
    Ok(())
}
