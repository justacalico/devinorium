//! Provider API routes: list configured providers and test a command.

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::Deserialize;

use crate::auth::session::CurrentUser;
use crate::providers;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/providers", get(list))
        .route("/api/providers/health", post(health))
}

async fn list(CurrentUser(_user): CurrentUser) -> Response {
    axum::Json(providers::available_providers()).into_response()
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
