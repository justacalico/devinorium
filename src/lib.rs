//! Devinorium library crate — a secure, self-hostable Material 3 web UI for
//! AI coding agents.
//!
//! The binary target (`src/main.rs`) is a thin wrapper around this library.

pub mod api;
pub mod assets;
pub mod auth;
pub mod config;
pub mod db;
pub mod federation;
pub mod git;
pub mod lock;
pub mod machine_grants;
pub mod mcp;
pub mod mcpb;
pub mod node;
pub mod node_client;
pub mod plan;
pub mod projects;
pub mod providers;
pub mod push;
pub mod satellite;
pub mod security;
pub mod skills;
pub mod ssh;
pub mod tailscale;
pub mod terminal;
pub mod thread_runner;
pub mod update;
pub mod vnc;

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

/// An ask request that is awaiting a user response.
pub struct PendingAskRequest {
    pub user_id: i64,
    pub thread_id: String,
    pub sender: oneshot::Sender<Option<HashMap<String, serde_json::Value>>>,
}

/// Shared application state passed to all axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
    pub provider: Arc<dyn providers::Provider>,
    /// Startup probe results for each provider's backing CLI, so the API can
    /// report which providers are installed on this host.
    pub provider_status: providers::ProviderStatusCache,
    pub pending_permission_requests: Arc<Mutex<HashMap<String, PendingPermissionRequest>>>,
    pub pending_ask_requests: Arc<Mutex<HashMap<String, PendingAskRequest>>>,
    pub thread_runner: crate::thread_runner::ThreadRunner,
    pub git: Arc<crate::git::GitService>,
    pub git_remote: Arc<crate::git::GitRemoteService>,
    pub terminal_manager: crate::terminal::manager::TerminalManager,
    /// `tailscale` CLI client used by the Tailscale endpoints.
    pub tailscale: crate::tailscale::Tailscale,
    /// Capability tokens minted for runs that reference machines.
    pub machine_grants: machine_grants::MachineGrants,
    /// Web Push sender for run lifecycle events; `PushService::disabled()`
    /// in tests.
    pub push: push::PushService,
    /// The address the listener actually bound, set once after startup.
    /// Machine-control instructions point agents at this so `--dev`'s
    /// random port and wildcard binds resolve to a reachable URL.
    pub bound_addr: Arc<std::sync::OnceLock<std::net::SocketAddr>>,
    /// Outbound HTTP client for calls to paired satellite nodes. Has no
    /// overall timeout so run event streams can stay open indefinitely.
    pub http_client: reqwest::Client,
    /// Terminal sessions hosted on a satellite node, keyed by the session id
    /// the node returned. Entries die with the session or a hub restart;
    /// the satellite's own idle sweep reclaims strays.
    pub remote_terminals:
        Arc<std::sync::Mutex<HashMap<String, db::federation_nodes::FederationNodeRow>>>,
    /// Shared weighted token bucket. The global middleware charges by
    /// endpoint class; auth/login code debits extra on failures so probes
    /// cannot hide behind header tricks or rotating source IPs.
    pub rate_limiter: security::RateLimiter,
}

impl AppState {
    /// Base URL agents on this host use for the machine-control API.
    /// Prefers the bound socket; falls back to the configured host/port,
    /// mapping a wildcard bind to loopback.
    pub fn agent_base_url(&self) -> String {
        let (host, port) = match self.bound_addr.get() {
            Some(addr) => {
                let ip = addr.ip();
                (
                    if ip.is_unspecified() {
                        "127.0.0.1".to_string()
                    } else {
                        ip.to_string()
                    },
                    addr.port(),
                )
            }
            None => {
                let raw = self
                    .config
                    .host
                    .trim_start_matches('[')
                    .trim_end_matches(']');
                let host = match raw.parse::<std::net::IpAddr>() {
                    Ok(ip) if ip.is_unspecified() => "127.0.0.1".to_string(),
                    _ => raw.to_string(),
                };
                (host, self.config.port)
            }
        };
        if host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_ipv6())
        {
            format!("http://[{host}]:{port}")
        } else {
            format!("http://{host}:{port}")
        }
    }
}

impl AppState {
    /// Build a provider for the given user's default provider.
    pub fn provider_for_user(&self, user: &db::UserRow) -> Arc<dyn providers::Provider> {
        self.provider_for(user, &user.provider_id)
    }

    /// Build the provider `provider_id` using the command the user configured
    /// for it (see [`db::UserRow::command_for_provider`]). Falls back to the
    /// configured default provider when no command is set, which only happens
    /// in tests that inject a stub provider.
    pub fn provider_for(
        &self,
        user: &db::UserRow,
        provider_id: &str,
    ) -> Arc<dyn providers::Provider> {
        let command = user.command_for_provider(provider_id);
        if command.is_empty() {
            return self.provider.clone();
        }

        match providers::build_provider(providers::ProviderConfig {
            id: provider_id.to_string(),
            command: command.clone(),
            default_model: self.config.default_model.clone(),
        }) {
            Ok(p) => Arc::from(p),
            Err(e) => {
                tracing::warn!(
                    user_id = %user.id,
                    provider_id = %provider_id,
                    command = %command,
                    error = %e,
                    "failed to build user provider; falling back to default"
                );
                self.provider.clone()
            }
        }
    }
}

/// Build the full axum application router with all security middleware.
///
/// This is shared by the binary target and the integration tests so that
/// tests exercise the exact same middleware stack as production.
pub fn build_app(state: AppState) -> Router {
    let dev_mode = state.config.dev_mode;
    let dev_loopback = dev_mode && config::is_loopback_host(&state.config.host);
    let trust_proxy = state.config.trust_proxy;
    let csrf_allowed = state.config.allowed_origin.clone();
    let cors_allowed = state.config.allowed_origin.clone();
    let max_body = state.config.max_body_bytes;

    // Global weighted rate limiter.
    //
    // Capacity 500 tokens, refill 2/sec. Each endpoint class has a cost:
    //   - login:           20 tokens (25 attempts before throttle)
    //   - TOTP verify:     15 tokens
    //   - unauth probe:    25 tokens (20 attempts before throttle)
    //   - auth write:       2 tokens (250 writes before throttle)
    //   - auth read/logout: 0 tokens (free, never throttled)
    //
    // This means a brute-force attacker depletes the bucket in ~25 tries,
    // while a normal authenticated user can browse freely and send many
    // messages before being throttled. After depletion, 1 login every 10s.
    // The instance lives on AppState so auth handlers can debit the same
    // buckets on credential failures.
    let limiter = state.rate_limiter.clone();

    // Public routes (no auth). Machine-control endpoints authenticate
    // with per-run capability tokens inside their handlers.
    let public = api::auth::router()
        .merge(api::server::router())
        .merge(api::machine_control::router())
        .route_layer(RequestBodyLimitLayer::new(max_body));

    // Protected routes (require auth + role=user).
    let protected = api::threads::router()
        .merge(api::files::router())
        .merge(api::projects::router())
        .merge(api::project_groups::router())
        .merge(api::clones::router())
        .merge(api::git::router())
        .merge(api::git_connections::router())
        .merge(api::thread_groups::router())
        .merge(api::terminal::router())
        .merge(api::accounts::router())
        .merge(api::audit::router())
        .merge(api::settings::router())
        .merge(api::machines::router())
        .merge(api::federation::router())
        .merge(api::tailscale::router())
        .merge(api::models::router())
        .merge(api::providers::router())
        .merge(api::push::router())
        .merge(api::update::router())
        .merge(api::usage::router())
        .route("/api/auth/me", get(api::auth::me))
        .route("/api/auth/me", axum::routing::patch(api::auth::update_me))
        .route(
            "/api/auth/me/password",
            axum::routing::patch(api::auth::change_password),
        )
        .route(
            "/api/auth/totp/setup",
            axum::routing::post(api::auth::totp_setup),
        )
        .route(
            "/api/auth/totp/verify",
            axum::routing::post(api::auth::totp_verify),
        )
        .route(
            "/api/auth/totp/disable",
            axum::routing::post(api::auth::totp_disable),
        )
        // Bound multipart fields by the configured body limit; axum's
        // default 2 MiB field limit would otherwise reject large
        // attachments before the handlers' own checks run.
        .route_layer(axum::extract::DefaultBodyLimit::max(max_body))
        .route_layer(RequestBodyLimitLayer::new(max_body))
        .route_layer(from_fn_with_state(
            state.clone(),
            auth::middleware::require_auth,
        ));

    // Message sends carry user text of any length, so they opt out of both
    // body caps. Auth still runs first, rejecting unauthenticated posts
    // before the body is read.
    let protected_sends = api::threads::send_router()
        .route_layer(axum::extract::DefaultBodyLimit::disable())
        .route_layer(from_fn_with_state(
            state.clone(),
            auth::middleware::require_auth,
        ));

    // .mcpb uploads are full server bundles — bigger than the default body
    // cap, so they get their own limit instead of `max_body`.
    let protected_mcpb = api::settings::mcpb_router()
        .route_layer(axum::extract::DefaultBodyLimit::max(mcpb::MAX_MCPB_BYTES))
        .route_layer(RequestBodyLimitLayer::new(mcpb::MAX_MCPB_BYTES))
        .route_layer(from_fn_with_state(
            state.clone(),
            auth::middleware::require_auth,
        ));

    let mut app = Router::new()
        .route(
            "/healthz",
            get(|| async { axum::Json(serde_json::json!({"status": "ok"})) }),
        )
        .merge(public)
        .merge(protected)
        .merge(protected_sends)
        .merge(protected_mcpb)
        .merge(assets::router())
        .layer(from_fn(security::security_headers))
        .layer(from_fn(move |req, next| {
            let ao = csrf_allowed.clone();
            async move { security::csrf_origin_check(ao, req, next).await }
        }))
        // Global weighted rate limiter — runs after IP extraction (so it
        // can read the client IP from extensions). Layers registered later
        // run first, so the trace layer has already run by now. Per-route
        // body limits run inside routing, after this point.
        .layer(from_fn(move |req, next| {
            let lim = limiter.clone();
            async move { security::global_weighted_rate_limit(lim, req, next).await }
        }))
        .layer(from_fn(move |req, next| {
            let tp = trust_proxy;
            async move { security::extract_client_ip(tp, req, next).await }
        }))
        .layer(TraceLayer::new_for_http())
        .layer(CompressionLayer::new());

    // Opt-in CORS for native clients. Only enabled when the admin explicitly
    // sets DEVINORIUM_ALLOWED_ORIGIN. Same-origin web requests are unaffected.
    if let Some(cors) = security::cors::build_cors_layer(&cors_allowed) {
        app = app.layer(cors);
    }

    // Dev mode serves every request as the local owner with no credentials.
    // On a loopback bind (`--local`), confine Host headers to loopback as
    // the outermost layer: DNS rebinding would otherwise let a remote web
    // page drive the API. On a public bind the check cannot tell a
    // rebinding browser from a real remote client, so it is skipped.
    if dev_loopback {
        app = app.layer(from_fn(security::dev_host_check));
    }

    app.with_state(state)
}
