//! Devinorium — a secure, self-hostable Material 3 web UI for the Devin CLI.

mod auth;
mod config;
mod db;

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

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
}

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
    let state = AppState {
        config: Arc::new(cfg),
        db: database,
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
