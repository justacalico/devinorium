//! Models API route: list models offered by the configured provider.

use axum::extract::State;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::routing::Router;

use crate::auth::session::CurrentUser;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/models", get(list))
}

async fn list(State(state): State<AppState>, CurrentUser(_user): CurrentUser) -> Response {
    match state.provider.list_models().await {
        Ok(models) => axum::Json(models).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
