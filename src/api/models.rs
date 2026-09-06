//! Models API route: list models offered by a provider.

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::routing::Router;
use serde::Deserialize;

use crate::auth::session::CurrentUser;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/models", get(list))
}

#[derive(Debug, Deserialize)]
pub struct ListModels {
    /// Provider whose models to list. Defaults to the user's configured
    /// provider.
    pub provider: Option<String>,
}

async fn list(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(query): Query<ListModels>,
) -> Response {
    let provider_id = query
        .provider
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&user.provider_id);
    if crate::providers::provider_name(provider_id).is_none() {
        return (
            axum::http::StatusCode::BAD_REQUEST,
            axum::Json(crate::api::ApiError::new("unknown provider")),
        )
            .into_response();
    }
    let provider = state.provider_for(&user, provider_id);
    match provider.list_models().await {
        Ok(models) => axum::Json(models).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
