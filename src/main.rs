//! Devinorium — a secure, self-hostable Material 3 web UI for the Devin CLI.

use std::sync::Arc;

use anyhow::Result;
use axum::{
    routing::get,
    Router,
};
use tower_http::{
    compression::CompressionLayer,
    trace::TraceLayer,
};

use devinorium::{auth, config, db, providers, AppState};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "devinorium=info,tower_http=info".into()),
        )
        .init();

    let cfg = config::Config::from_env()?;
    let bind = cfg.bind_addr();
    let database = db::Db::connect(&cfg.db_url).await?;

    // First-run bootstrap: create the initial owner account if none exist.
    auth::bootstrap::run(&database, &cfg.bootstrap_username, &cfg.bootstrap_password).await?;

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".to_string(),
        devin_bin: cfg.devin_bin.clone(),
        default_model: cfg.default_model.clone(),
    })?;

    let state = AppState {
        config: Arc::new(cfg),
        db: database,
        provider: Arc::from(provider),
    };

    // Public routes (no auth).
    let public = devinorium::api::auth::router();

    // Protected routes (require auth + role=user).
    let protected = devinorium::api::threads::router()
        .merge(devinorium::api::files::router())
        .merge(devinorium::api::workspaces::router())
        .route("/api/auth/me", axum::routing::get(devinorium::api::auth::me))
        .route(
            "/api/auth/totp/setup",
            axum::routing::post(devinorium::api::auth::totp_setup),
        )
        .route(
            "/api/auth/totp/verify",
            axum::routing::post(devinorium::api::auth::totp_verify),
        )
        .route(
            "/api/auth/totp/disable",
            axum::routing::post(devinorium::api::auth::totp_disable),
        )
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            auth::middleware::require_auth,
        ));

    let app = Router::new()
        .route("/healthz", get(healthz))
        .merge(public)
        .merge(protected)
        .with_state(state)
        .layer(TraceLayer::new_for_http())
        .layer(CompressionLayer::new());

    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!("Devinorium listening on http://{}", bind);
    axum::serve(listener, app).await?;
    Ok(())
}

async fn healthz() -> &'static str {
    "ok"
}
