//! Context usage: the thread's recorded token totals and session state.
//!
//! The provider session holds the real context and compacts or truncates it
//! itself, so nothing here estimates tokens or gates sends. The recorded
//! totals come from `usage_events` and are the numbers the UI shows.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::UsageTotals;
use crate::AppState;

/// What `GET /api/threads/:id/context` reports.
#[derive(Debug, Clone, Serialize)]
pub struct ContextUsageOut {
    /// Whether a live provider session exists — that is, whether resetting
    /// context would drop anything.
    pub has_session: bool,
    /// The thread's recorded token totals across all turns.
    pub usage: UsageTotals,
}

/// `GET /api/threads/:id/context` — the usage numbers the composer shows.
pub(super) async fn get_context(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    let usage = match state.db.thread_usage_totals(user.id, &id).await {
        Ok(t) => t,
        Err(e) => return map_err_internal(e).into_response(),
    };
    Json(ContextUsageOut {
        has_session: thread.devin_session_id.is_some(),
        usage,
    })
    .into_response()
}

/// `POST /api/threads/:id/context/reset` — drop the provider session and
/// move the usage watermark to now. The next send starts a fresh session.
pub(super) async fn reset_context(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    // Finished runs stay in the runner for a retention window, so the check
    // has to look at the status rather than presence.
    if let Some(run) = state.thread_runner.get(&id).await {
        if *run.status.read().await == crate::thread_runner::RunStatus::Running {
            return (
                StatusCode::CONFLICT,
                Json(ApiError::new("cannot reset context while a run is active")),
            )
                .into_response();
        }
    }
    match state.db.reset_thread_context(&id, user.id).await {
        Ok(0) => (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response(),
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}
