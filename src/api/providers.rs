//! Provider API routes: list configured providers.

use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::routing::Router;

use crate::auth::session::CurrentUser;
use crate::providers;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/providers", get(list))
}

async fn list(CurrentUser(_user): CurrentUser) -> Response {
    axum::Json(providers::available_providers()).into_response()
}
