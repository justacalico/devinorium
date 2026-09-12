//! Auto worktree creation for threads.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

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

    match state
        .db
        .update_thread_git(&thread.id, user.id, Some(&branch), Some(&worktree_path))
        .await
    {
        Ok(0) => {
            // The thread was deleted while `git worktree add` was in
            // flight; undo the worktree and its branch so they do not leak.
            let _ = state
                .git
                .remove_worktree(&status.toplevel, &worktree.1.path)
                .await;
            let _ = state.git.prune_worktrees(&status.toplevel).await;
            let _ = state.git.delete_branch(&status.toplevel, &branch).await;
            anyhow::bail!("thread was deleted");
        }
        Ok(_) => {}
        Err(e) => {
            // Same rollback: the row never learned about the worktree, so
            // no cleanup path would ever find it again.
            let _ = state
                .git
                .remove_worktree(&status.toplevel, &worktree.1.path)
                .await;
            let _ = state.git.prune_worktrees(&status.toplevel).await;
            let _ = state.git.delete_branch(&status.toplevel, &branch).await;
            return Err(e);
        }
    }

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
    let project = state
        .db
        .get_project(project_id, thread.user_id)
        .await
        .ok()??;
    let project_path = PathBuf::from(&project.path);
    state
        .git
        .worktrees(&project_path, true)
        .await
        .ok()
        .map(|wts| {
            wts.into_iter()
                .map(|w| w.path.to_string_lossy().into_owned())
                .collect()
        })
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

/// Best-effort removal of the worktree and branch a deleted thread leaves
/// behind.
///
/// Only resources this backend created are touched, identified by the
/// generated `devinorium/*` branch name: a worktree still checked out on
/// the thread's branch is removed wherever it lives, a leftover directory
/// inside the managed worktrees root is deleted, and the branch itself is
/// deleted. A worktree on any other branch is left alone, even when the
/// thread row points at it: `branch` and `worktree_path` are writable
/// through the API and cannot be trusted on their own. Errors are logged,
/// never returned; the thread row is already gone by the time this runs.
pub(crate) async fn cleanup_thread_worktree(
    state: &AppState,
    thread: &ThreadRow,
    repo_hint: Option<&Path>,
) {
    let branch = thread
        .branch
        .as_deref()
        .map(str::trim)
        .filter(|b| !b.is_empty());
    let Some(branch) = branch else { return };
    if !wt::is_temporary_worktree_branch(branch) {
        return;
    }
    let wt_path = thread
        .worktree_path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(PathBuf::from);

    // The repo to run cleanup in: the project checkout while the project
    // row still resolves, then the caller's hint, then the thread's stored
    // worktree path. `git worktree list` yields the main checkout as its
    // first entry, which anchors the managed root for linked worktrees.
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(project_id) = thread.project_id {
        if let Ok(Some(project)) = state.db.get_project(project_id, thread.user_id).await {
            candidates.push(PathBuf::from(project.path));
        }
    }
    if let Some(hint) = repo_hint {
        candidates.push(hint.to_path_buf());
    }
    if let Some(path) = &wt_path {
        candidates.push(path.clone());
    }
    let mut resolved = None;
    for cand in candidates {
        if let Ok(worktrees) = state.git.worktrees(&cand, true).await {
            if let Some(main) = worktrees.iter().find(|w| w.is_main) {
                resolved = Some((main.path.clone(), worktrees));
                break;
            }
        }
    }
    let Some((repo, worktrees)) = resolved else {
        return;
    };
    // Git commands run from the main checkout: a linked worktree cannot
    // remove itself, and the main path always resolves.
    let managed_root = wt::managed_worktrees_root(&repo);

    // A worktree checked out on the thread's temp branch is provably ours:
    // remove it wherever it is, covering `git worktree move` and a stored
    // path that diverged from the deterministic managed location.
    for w in &worktrees {
        if !w.is_main && w.branch.as_deref() == Some(branch) {
            if let Err(e) = state.git.remove_worktree(&repo, &w.path).await {
                tracing::warn!(error = %e, thread_id = %thread.id, path = %w.path.display(), "thread worktree removal failed");
            }
        }
    }

    // Directories inside the managed root that are not registered worktrees
    // are leftovers, for example a registration pruned while the directory
    // stayed behind. Re-list first: a worktree registered at the same path
    // since the snapshot above belongs to someone else and must survive.
    let worktrees_now = state
        .git
        .worktrees(&repo, true)
        .await
        .unwrap_or_else(|_| worktrees.clone());
    let managed_path = wt::managed_worktree_path(&repo, branch);
    for candidate in [wt_path.as_deref(), Some(managed_path.as_path())] {
        let Some(path) = candidate else { continue };
        if path.parent() != Some(managed_root.as_path())
            || worktrees_now.iter().any(|w| w.path == path)
            || !matches!(tokio::fs::try_exists(path).await, Ok(true))
        {
            continue;
        }
        let _ = tokio::fs::remove_dir_all(path).await;
    }

    // Clear stale registrations so the branch delete cannot fail with
    // "checked out at" for a worktree whose directory is already gone.
    let _ = state.git.prune_worktrees(&repo).await;
    if let Err(e) = state.git.delete_branch(&repo, branch).await {
        tracing::warn!(error = %e, thread_id = %thread.id, "thread branch removal failed");
    }

    let _ = state.git.worktrees(&repo, true).await;
}
