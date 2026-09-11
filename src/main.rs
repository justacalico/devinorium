//! Devinorium — a secure, self-hostable Material 3 web UI for AI coding agents.

use std::sync::Arc;

use anyhow::Result;

use devinorium::{auth, config, db, git, lock, providers, AppState};

#[tokio::main]
async fn main() -> Result<()> {
    // Load .env file if present (ignored if not found). In bundled local
    // mode the launcher already controls the environment; a .env in the
    // server's working directory must not reintroduce DEVINORIUM_* settings
    // (e.g. a bootstrap password would create an interactive owner account).
    if std::env::var("DEVINORIUM_LOCAL_TOKEN")
        .map(|v| v.is_empty())
        .unwrap_or(true)
    {
        let _ = dotenvy::dotenv();
    }

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

    if cfg.is_local_mode() {
        // Bundled mode: the passwordless local account backs every request
        // carrying the configured token.
        auth::bootstrap::run_local(&database).await?;
        // The desktop app holds our stdin pipe; when it exits or crashes the
        // pipe closes and we shut down instead of lingering as an orphan.
        spawn_stdin_watchdog();
    }

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".to_string(),
        command: "devin".to_string(),
        default_model: cfg.default_model.clone(),
    })?;

    // Probe each registered provider's CLI in the background so the first
    // /api/providers response already knows which providers this host has.
    let provider_status = providers::ProviderStatusCache::new();
    {
        let cache = provider_status.clone();
        tokio::spawn(async move {
            for (id, status) in cache.probe_registered().await {
                if status.is_ready() {
                    tracing::info!(provider = %id, version = ?status.version, "provider available");
                } else {
                    tracing::warn!(
                        provider = %id,
                        message = ?status.message,
                        "provider unavailable"
                    );
                }
            }
        });
    }

    let secure_cookie = cfg.secure_cookie;
    let cfg = Arc::new(cfg);
    let state = AppState {
        config: cfg.clone(),
        db: database,
        provider: Arc::from(provider),
        provider_status,
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        pending_ask_requests: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        terminal_manager: devinorium::terminal::manager::TerminalManager::default_manager(),
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

/// Exit the process once stdin reaches EOF. Used in bundled local mode, where
/// the Flutter app owns stdin: a closed pipe means the app is gone.
fn spawn_stdin_watchdog() {
    tokio::task::spawn_blocking(|| {
        use std::io::Read;
        let mut stdin = std::io::stdin().lock();
        let mut buf = [0u8; 256];
        loop {
            match stdin.read(&mut buf) {
                // EOF or a broken pipe: the parent is gone.
                Ok(0) | Err(_) => std::process::exit(0),
                Ok(_) => {}
            }
        }
    });
}
