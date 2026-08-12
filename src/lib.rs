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

use std::collections::HashMap;
use std::sync::Arc;

use axum::middleware::{from_fn, from_fn_with_state};
use axum::routing::get;
use axum::Router;
use tokio::sync::{oneshot, Mutex};
use tower_http::{compression::CompressionLayer, limit::RequestBodyLimitLayer, trace::TraceLayer};

/// A permission request that is awaiting a user decision.
pub struct PendingPermissionRequest {
    pub user_id: i64,
    pub thread_id: String,
    pub sender: oneshot::Sender<String>,
}

/// Shared application state passed to all axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
    pub provider: Arc<dyn providers::Provider>,
    pub pending_permission_requests: Arc<Mutex<HashMap<String, PendingPermissionRequest>>>,
}

/// Build the full axum application router with all security middleware.
///
/// This is shared by the binary target and the integration tests so that
/// tests exercise the exact same middleware stack as production.
pub fn build_app(state: AppState) -> Router {
    let trust_proxy = state.config.trust_proxy;
    let allowed_origin = state.config.allowed_origin.clone();
    let max_body = state.config.max_body_bytes;

    // Global weighted rate limiter.
    //
    // Capacity 500 tokens, refill 2/sec. Each endpoint class has a cost:
    //   - login/register: 20 tokens (25 attempts before throttle)
    //   - TOTP verify:    15 tokens
    //   - unauth probe:   25 tokens (20 attempts before throttle)
    //   - auth write:      2 tokens (250 writes before throttle)
    //   - invite create:   5 tokens
    //   - auth read/logout: 0 tokens (free, never throttled)
    //
    // This means a brute-force attacker depletes the bucket in ~25 tries,
    // while a normal authenticated user can browse freely and send many
    // messages before being throttled. After depletion, 1 login every 10s.
    let limiter = security::RateLimiter::new(500, 2.0);

    // Public routes (no auth).
    let public = api::auth::router();

    // Protected routes (require auth + role=user).
    let protected = api::threads::router()
        .merge(api::files::router())
        .merge(api::projects::router())
        .merge(api::thread_groups::router())
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
        // Global weighted rate limiter — runs after IP extraction (so it can
        // read the client IP from extensions) but before body limit/trace.
        .layer(from_fn(move |req, next| {
            let lim = limiter.clone();
            async move { security::global_weighted_rate_limit(lim, req, next).await }
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
