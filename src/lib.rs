//! Devinorium library crate — a secure, self-hostable Material 3 web UI for
//! the Devin CLI.
//!
//! The binary target (`src/main.rs`) is a thin wrapper around this library.

pub mod api;
pub mod assets;
pub mod auth;
pub mod config;
pub mod db;
pub mod providers;
pub mod security;

use std::sync::Arc;

use axum::middleware::{from_fn, from_fn_with_state, Next};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::extract::Request;
use axum::Router;
use tower_http::{compression::CompressionLayer, limit::RequestBodyLimitLayer, trace::TraceLayer};

/// Shared application state passed to all axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
    pub provider: Arc<dyn providers::Provider>,
}

/// Build the full axum application router with all security middleware.
///
/// This is shared by the binary target and the integration tests so that
/// tests exercise the exact same middleware stack as production.
pub fn build_app(state: AppState) -> Router {
    let trust_proxy = state.config.trust_proxy;
    let allowed_origin = state.config.allowed_origin.clone();
    let max_body = state.config.max_body_bytes;

    // Rate limiter for unauthenticated auth endpoints (10/min per IP).
    let auth_limiter = security::RateLimiter::new(10, 1.0 / 60.0);

    // Public routes (no auth), rate-limited.
    let public = api::auth::router().route_layer(from_fn(move |req: Request, next: Next| {
        let limiter = auth_limiter.clone();
        async move {
            let ip = security::ip_from_req(&req);
            if !limiter.check("auth", &ip).await {
                return (
                    axum::http::StatusCode::TOO_MANY_REQUESTS,
                    "rate limited",
                )
                    .into_response();
            }
            next.run(req).await
        }
    }));

    // Protected routes (require auth + role=user).
    let protected = api::threads::router()
        .merge(api::files::router())
        .merge(api::workspaces::router())
        .merge(api::invites::router())
        .merge(api::models::router())
        .route("/api/auth/me", get(api::auth::me))
        .route("/api/auth/totp/setup", axum::routing::post(api::auth::totp_setup))
        .route("/api/auth/totp/verify", axum::routing::post(api::auth::totp_verify))
        .route("/api/auth/totp/disable", axum::routing::post(api::auth::totp_disable))
        // Allow multipart fields up to 10 MiB so the per-attachment 8 MiB
        // check in the send handler is the effective gate (axum's default
        // multipart field limit is 2 MiB, which would shadow it).
        .route_layer(axum::extract::DefaultBodyLimit::max(10 * 1024 * 1024))
        .route_layer(from_fn_with_state(state.clone(), auth::middleware::require_auth));

    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .merge(public)
        .merge(protected)
        .merge(assets::router())
        .layer(from_fn(security::security_headers))
        .layer(from_fn(move |req, next| {
            let ao = allowed_origin.clone();
            async move { security::csrf_origin_check(ao, req, next).await }
        }))
        .layer(from_fn(move |req, next| {
            let tp = trust_proxy;
            async move { security::extract_client_ip(tp, req, next).await }
        }))
        .layer(RequestBodyLimitLayer::new(max_body))
        .layer(TraceLayer::new_for_http())
        .layer(CompressionLayer::new())
        .with_state(state)
}
