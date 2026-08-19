//! Devinorium — a secure, self-hostable Material 3 web UI for AI coding agents.

use std::sync::Arc;

use anyhow::Result;

use devinorium::{auth, config, db, git, lock, providers, AppState};

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env file if present (ignored if not found).
    let _ = dotenvy::dotenv();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "devinorium=info,tower_http=info".into()),
        )
        .init();

    let cfg = config::Config::from_env()?;

    let _guard = lock::lock_path_from_db_url(&cfg.db_url)
        .map(|p| lock::SingleInstance::acquire(&p))
        .transpose()?;

    let bind = cfg.bind_addr();
    let database = db::Db::connect(&cfg.db_url).await?;

    // First-run bootstrap: create the initial owner account if none exist.
    auth::bootstrap::run(&database, &cfg.bootstrap_username, &cfg.bootstrap_password).await?;

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".to_string(),
        command: "devin".to_string(),
        default_model: cfg.default_model.clone(),
    })?;

    let secure_cookie = cfg.secure_cookie;
    let cfg = Arc::new(cfg);
    let state = AppState {
        config: cfg.clone(),
        db: database,
        provider: Arc::from(provider),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        pending_ask_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        git: Arc::new(git::GitService::new()),
        git_remote: Arc::new(git::GitRemoteService::new(cfg.home_dir.clone())),
    };

    let app = devinorium::build_app(state);

    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind, secure_cookie, "Devinorium listening");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;
    Ok(())
}
