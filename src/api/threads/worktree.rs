//! Auto worktree creation for threads.

use std::collections::HashSet;
use std::path::PathBuf;

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

/// Snapshot the set of worktree paths for a thread's project repo, so a later
/// call to [`sync_agent_created_worktree`] can tell which worktrees appeared
/// during the run. Returns `None` when the thread has no project or the repo
/// cannot be read; detection is then skipped to avoid mistaking pre-existing
/// worktrees for agent-created ones.
pub(crate) async fn snapshot_worktree_paths(
    state: &AppState,
    thread: &ThreadRow,
) -> Option<HashSet<String>> {
    let project_id = thread.project_id?;
    let project = state.db.get_project(project_id, thread.user_id).await.ok()??;
    let project_path = PathBuf::from(&project.path);
    state
        .git
        .worktrees(&project_path, true)
        .await
        .ok()
        .map(|wts| wts.into_iter().map(|w| w.path.to_string_lossy().into_owned()).collect())
}

/// After a run, detect worktrees the agent created on its own (e.g. via
/// `git worktree add`) and associate the thread with the newest one.
///
/// `before` is the snapshot returned by [`snapshot_worktree_paths`] taken
/// before the run. `None` means the snapshot failed and detection is skipped
/// to avoid mistaking pre-existing worktrees for new ones. Any non-main
/// worktree in the current list that was not in `before` is treated as
/// agent-created. The thread is only reassociated when it still points at the
/// main worktree (no `worktree_path`), so an explicit or auto-created worktree
/// is never overridden.
///
/// When a new worktree is found the thread is flipped to worktree mode so
/// future prompts keep running inside it. Returns `true` when the thread was
/// updated.
pub(crate) async fn sync_agent_created_worktree(
    state: &AppState,
    user: &UserRow,
    thread: &mut ThreadRow,
    before: Option<&HashSet<String>>,
) -> anyhow::Result<bool> {
    if let Some(p) = &thread.worktree_path {
        if !p.is_empty() {
            return Ok(false);
        }
    }

    let Some(before) = before else {
        return Ok(false);
    };

    let Some(project_id) = thread.project_id else {
        return Ok(false);
    };
    let project = match state.db.get_project(project_id, user.id).await? {
        Some(p) => p,
        None => return Ok(false),
    };
    let project_path = PathBuf::from(&project.path);

    let worktrees = match state.git.worktrees(&project_path, true).await {
        Ok(wts) => wts,
        Err(e) => {
            tracing::warn!(error = %e, "git worktree list failed during agent sync");
            return Ok(false);
        }
    };

    let new_wts: Vec<_> = worktrees
        .into_iter()
        .filter(|w| !w.is_main)
        .filter(|w| !before.contains(&w.path.to_string_lossy().into_owned()))
        .collect();
    if new_wts.is_empty() {
        return Ok(false);
    }

    // Prefer the most recently created worktree when several appear, since the
    // agent may set up a scratch worktree before the one it actually works in.
    // mtime is a heuristic; the filesystem call is blocking so offload it.
    let paths_for_mtime: Vec<_> = new_wts.iter().map(|w| w.path.clone()).collect();
    let mtimes = tokio::task::spawn_blocking(move || {
        paths_for_mtime
            .into_iter()
            .map(|p| std::fs::metadata(&p).and_then(|m| m.modified()).ok())
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();
    // Pair each worktree with its mtime, sort ascending, take the newest.
    let mut paired: Vec<_> = new_wts
        .into_iter()
        .enumerate()
        .map(|(i, w)| (mtimes.get(i).cloned().flatten(), w))
        .collect();
    paired.sort_by_key(|(mtime, _)| *mtime);
    let target = paired.last().expect("filtered list is non-empty").1.clone();
    let worktree_path = target.path.to_string_lossy().into_owned();
    let branch = target.branch.clone();

    state
        .db
        .update_thread_git(&thread.id, user.id, branch.as_deref(), Some(&worktree_path))
        .await?;
    state
        .db
        .update_thread_env_mode(&thread.id, user.id, "worktree")
        .await?;

    // Refresh the cached worktree list so the UI menu includes the new entry.
    let _ = state.git.worktrees(&project_path, true).await;

    thread.worktree_path = Some(worktree_path);
    thread.branch = branch;
    thread.env_mode = "worktree".into();
    Ok(true)
}
