//! `GET /api/threads/:id/skills` — the skills discoverable in the thread's
//! working directory, feeding the composer's `/` picker.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::AppState;

use super::plan::project_working_dir_for_thread;

pub(super) async fn list_skills(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    // The same directory the agent runs in, so the picker offers exactly the
    // project skills the provider can see (worktree mode included).
    let cwd = match project_working_dir_for_thread(&state, &thread).await {
        Ok(p) => p,
        Err(e) => return map_err_internal(e).into_response(),
    };
    let skills = crate::skills::discover_skills(&cwd, &state.config.home_dir).await;
    Json(serde_json::json!({
        "skills": skills.iter().map(|s| &s.info).collect::<Vec<_>>(),
    }))
    .into_response()
}
