//! Provider API routes: list configured providers, test a command, and
//! report version information for the current user's provider.

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::providers;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/providers", get(list))
        .route("/api/providers/version", get(version))
        .route("/api/providers/health", post(health))
}

async fn list(CurrentUser(_user): CurrentUser) -> Response {
    axum::Json(providers::available_providers()).into_response()
}

#[derive(Debug, Serialize)]
pub struct ProviderVersionResponse {
    pub provider_id: String,
    pub provider_name: String,
    pub installed_version: Option<String>,
    pub latest_version: Option<String>,
    pub update_available: bool,
}

/// Report the installed and latest versions for the current user's
/// configured provider. Best effort: when the binary or the update
/// manifest is unreachable the corresponding fields are null.
async fn version(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    let provider = state.provider_for_user(&user);
    let info = provider.version_info().await;
    let update_available = info.update_available();
    Json(ProviderVersionResponse {
        provider_id: provider.id().to_string(),
        provider_name: provider.name().to_string(),
        installed_version: info.installed,
        latest_version: info.latest,
        update_available,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct HealthRequest {
    pub provider_id: Option<String>,
    pub command: Option<String>,
}

async fn health(
    State(state): State<AppState>,
    CurrentUser(_user): CurrentUser,
    Json(req): Json<HealthRequest>,
) -> Response {
    let provider_id = req.provider_id.as_deref().unwrap_or("").trim();
    let command = req.command.as_deref().unwrap_or("").trim();

    if provider_id.is_empty() || command.is_empty() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new(
                "provider_id and command are required",
            )),
        )
            .into_response();
    }

    let valid_ids: std::collections::HashSet<_> = providers::available_providers()
        .into_iter()
        .map(|p| p.id)
        .collect();
    if !valid_ids.contains(provider_id) {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("unknown provider")),
        )
            .into_response();
    }

    let provider = match providers::build_provider(providers::ProviderConfig {
        id: provider_id.to_string(),
        command: command.to_string(),
        default_model: state.config.default_model.clone(),
    }) {
        Ok(p) => p,
        Err(e) => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(format!(
                    "failed to build provider: {e}"
                ))),
            )
                .into_response()
        }
    };

    match provider.health_check().await {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => (
            axum::http::StatusCode::BAD_GATEWAY,
            Json(crate::api::ApiError::new(format!(
                "provider health check failed: {e}"
            ))),
        )
            .into_response(),
    }
}
