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

use devinorium::{config, db, providers, AppState};

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

    let app = Router::new()
        .route("/healthz", get(healthz))
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
