//! Server self-update routes.
//!
//! `GET /api/server/update/check` reports whether a newer stable release
//! exists on GitLab. `POST /api/server/update/apply` downloads the release
//! binary for this platform, verifies its SHA-256 against the published
//! checksums, swaps it in, and restarts the process. Both are owner-only:
//! an update replaces the running binary, which is an admin action.
//!
//! The bundled desktop server (`local_mode`) and `--dev` instances refuse
//! updates: the app package owns the former's binary, and the latter is a
//! throwaway on a random port.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::Serialize;

use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::update::{self, NotUpdatable, UpdateEnv, UpdateError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/server/update/check", get(check))
        .route("/api/server/update/apply", post(apply))
}

#[derive(Debug, Serialize)]
struct ApplyResponse {
    status: &'static str,
    version: String,
}

fn env_of(state: &AppState) -> UpdateEnv {
    UpdateEnv {
        local_mode: state.config.is_local_mode(),
        dev_mode: state.config.dev_mode,
    }
}

fn not_updatable_response(reason: NotUpdatable) -> Response {
    let message = match reason {
        NotUpdatable::LocalMode => "the bundled server is updated with the app",
        NotUpdatable::DevMode => "development instances cannot be updated",
        NotUpdatable::UnsupportedPlatform => "no prebuilt release is published for this platform",
    };
    (StatusCode::CONFLICT, Json(ApiError::new(message))).into_response()
}

fn update_error_response(e: UpdateError) -> Response {
    if let UpdateError::NotUpdatable(reason) = &e {
        return not_updatable_response(*reason);
    }
    let (status, message) = match &e {
        UpdateError::InProgress => (StatusCode::CONFLICT, e.to_string()),
        UpdateError::NoUpdate | UpdateError::NoAsset => (StatusCode::CONFLICT, e.to_string()),
        other => {
            tracing::error!("server update failed: {other}");
            (StatusCode::BAD_GATEWAY, "update failed".to_string())
        }
    };
    (status, Json(ApiError::new(message))).into_response()
}

async fn check(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    match update::service().check(env_of(&state)).await {
        Ok(info) => Json(info).into_response(),
        Err(e) => {
            tracing::warn!("update check failed: {e}");
            (
                StatusCode::BAD_GATEWAY,
                Json(ApiError::new("update check failed")),
            )
                .into_response()
        }
    }
}

async fn apply(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    let env = env_of(&state);
    if let Some(reason) = env.not_updatable() {
        return not_updatable_response(reason);
    }
    if update::service().is_updating() {
        return (
            StatusCode::CONFLICT,
            Json(ApiError::new("an update is already in progress")),
        )
            .into_response();
    }

    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            tracing::error!("cannot resolve current executable: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiError::new("internal error")),
            )
                .into_response();
        }
    };

    match update::service().apply(env, &exe).await {
        Ok(applied) => {
            tracing::info!(version = %applied.version, tag = %applied.tag, "server update staged; restarting");
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "server.update",
                    &serde_json::json!({
                        "from": env!("CARGO_PKG_VERSION"),
                        "to": applied.version,
                        "tag": applied.tag,
                    }),
                    None,
                )
                .await;
            update::schedule_restart(applied.exe, applied.staged);
            Json(ApplyResponse {
                status: "restarting",
                version: applied.version,
            })
            .into_response()
        }
        Err(e) => update_error_response(e),
    }
}
