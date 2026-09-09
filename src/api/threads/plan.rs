//! Plan and project path helpers for threads.

use std::path::PathBuf;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::map_err_internal;
use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::db::ThreadRow;
use crate::AppState;

use super::persistence::active_run_plan;

/// Return the latest plan for a thread.
pub(super) async fn get_plan(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
    }

    let (has_active_run, active_plan) = active_run_plan(&state.thread_runner, &id).await;
    if has_active_run {
        return Json(serde_json::json!({
            "plan": active_plan,
            "updated_at": chrono::Utc::now().to_rfc3339(),
        }))
        .into_response();
    }

    match state.db.get_latest_plan(&id).await {
        Ok(Some(row)) => match row.to_plan() {
            Ok(plan) => Json(serde_json::json!({
                "plan": plan,
                "updated_at": row.updated_at,
            }))
            .into_response(),
            Err(e) => map_err_internal(e).into_response(),
        },
        Ok(None) => Json(serde_json::json!({"plan": None::<crate::plan::Plan>})).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn get_project_path(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => match t.project_id {
            Some(pid) => match state.db.get_project(pid, user.id).await {
                Ok(Some(p)) => Json(serde_json::json!({
                    "project_id": p.id,
                    "path": p.path,
                    "name": p.name,
                }))
                .into_response(),
                _ => (
                    StatusCode::NOT_FOUND,
                    Json(ApiError::new("project not found")),
                )
                    .into_response(),
            },
            None => (
                StatusCode::NOT_FOUND,
                Json(ApiError::new("thread has no project")),
            )
                .into_response(),
        },
        Ok(None) => (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Return the filesystem working directory for a thread.
///
/// If the thread belongs to a project, use the project's canonical path.
/// Otherwise fall back to the user's home directory.
pub(crate) async fn project_working_dir_for_thread(
    state: &AppState,
    thread: &ThreadRow,
) -> anyhow::Result<PathBuf> {
    if let Some(pid) = thread.project_id {
        if let Ok(Some(p)) = state.db.get_project(pid, thread.user_id).await {
            let project_path = tokio::fs::canonicalize(&p.path)
                .await
                .unwrap_or_else(|_| PathBuf::from(&p.path));
            if thread.env_mode == "worktree" {
                if let Some(wt) = &thread.worktree_path {
                    let path = PathBuf::from(wt);
                    if path.is_absolute() {
                        if let Ok(canonical) = tokio::fs::canonicalize(&path).await {
                            if let (Ok(project_repo), Ok(worktree_repo)) = (
                                state.git.repo_status(&project_path, false).await,
                                state.git.repo_status(&canonical, false).await,
                            ) {
                                if project_repo.is_repo
                                    && worktree_repo.is_repo
                                    && project_repo.common_dir == worktree_repo.common_dir
                                {
                                    return Ok(canonical);
                                }
                            }
                        }
                    }
                }
            }
            return Ok(project_path);
        }
    }
    Ok(state.config.home_dir.clone())
}

pub(crate) fn normalize_mode(raw: &str) -> String {
    let trimmed = raw.trim().to_lowercase();
    match trimmed.as_str() {
        "plan" => "plan".to_string(),
        "ask" => "ask".to_string(),
        _ => "code".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_mode;

    #[test]
    fn normalize_mode_maps_to_plan_ask_or_code() {
        assert_eq!(normalize_mode("plan"), "plan");
        assert_eq!(normalize_mode("PLAN"), "plan");
        assert_eq!(normalize_mode("  plan  "), "plan");
        assert_eq!(normalize_mode("ask"), "ask");
        assert_eq!(normalize_mode("code"), "code");
        assert_eq!(normalize_mode(""), "code");
        assert_eq!(normalize_mode("unknown"), "code");
    }
}
