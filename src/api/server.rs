//! Server metadata API routes.

use axum::routing::{get, Router};
use axum::{response::IntoResponse, Json};
use serde::Serialize;

use crate::AppState;

/// Public (unauthenticated) server metadata routes.
pub fn router() -> Router<AppState> {
    Router::new().route("/api/server/version", get(version))
}

#[derive(Debug, Serialize)]
pub struct ServerVersion {
    pub version: &'static str,
}

async fn version() -> impl IntoResponse {
    Json(ServerVersion {
        version: env!("CARGO_PKG_VERSION"),
    })
}
