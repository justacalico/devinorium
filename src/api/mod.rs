//! HTTP API routes.

pub mod auth;
pub mod files;
pub mod invites;
pub mod models;
pub mod threads;
pub mod workspaces;

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

/// A standard JSON error response.
#[derive(Debug, Serialize)]
pub struct ApiError {
    pub error: String,
}

impl ApiError {
    pub fn new(msg: impl Into<String>) -> Self {
        Self { error: msg.into() }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (StatusCode::BAD_REQUEST, Json(self)).into_response()
    }
}

/// Convenience: map an anyhow error to an ApiError with a generic message
/// that does not leak internals.
pub fn map_err_internal<E: std::fmt::Display>(e: E) -> (StatusCode, Json<ApiError>) {
    tracing::error!("internal error: {e}");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiError::new("internal error")),
    )
}
