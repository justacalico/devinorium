//! Provider API routes: list configured providers, test a command, and
//! report version information for the current user's provider.

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::providers;
use crate::providers::status::ProviderStatus;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/providers", get(list))
        .route("/api/providers/version", get(version))
        .route("/api/providers/health", post(health))
}

/// One provider entry in `GET /api/providers`: the registry metadata plus the
/// availability probe for the command the current user configured for it.
#[derive(Debug, Serialize)]
pub struct ProviderEntry {
    pub id: &'static str,
    pub name: &'static str,
    #[serde(flatten)]
    pub status: ProviderStatus,
}

/// List the registered providers with the availability probe result for the
/// command the current user configured for each. Providers whose binary is
/// missing are still listed so the frontend can show them greyed out, the
/// same shape t3code's `ServerProvider` snapshot uses.
async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    let entries =
        futures::future::join_all(providers::available_providers().into_iter().map(|p| {
            let state = state.clone();
            let command = user.command_for_provider(p.id);
            async move {
                let status = if command.is_empty() {
                    // An empty command means the app-level provider is in use,
                    // which only happens with an injected stub in tests.
                    ProviderStatus::ready()
                } else {
                    state.provider_status.status_for(&command).await
                };
                ProviderEntry {
                    id: p.id,
                    name: p.name,
                    status,
                }
            }
        }))
        .await;
    axum::Json(entries).into_response()
}

#[derive(Debug, Serialize)]
pub struct ProviderVersionResponse {
    pub provider_id: String,
    pub provider_name: String,
    pub installed_version: Option<String>,
    pub latest_version: Option<String>,
    pub update_available: bool,
}

#[derive(Debug, Deserialize)]
pub struct VersionQuery {
    /// Provider to report versions for. Defaults to the user's configured
    /// provider.
    pub provider: Option<String>,
}

/// Report the installed and latest versions for a provider. Best effort:
/// when the binary or the update manifest is unreachable the corresponding
/// fields are null.
async fn version(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    axum::extract::Query(query): axum::extract::Query<VersionQuery>,
) -> Response {
    let provider_id = query
        .provider
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&user.provider_id);
    if providers::provider_name(provider_id).is_none() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("unknown provider")),
        )
            .into_response();
    }
    let provider = state.provider_for(&user, provider_id);
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

    let result = provider.health_check().await;
    // The check just exercised the binary: re-probe on the next list so a
    // command the user just fixed or installed does not stay greyed out.
    state.provider_status.invalidate(command);
    match result {
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
