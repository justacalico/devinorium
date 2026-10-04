//! Satellite mode: a stateless agent runner.
//!
//! Started with `DEVINORIUM_SATELLITE=1`, the process has no database, no
//! accounts and no UI. It prints a pairing code at startup; the owner types
//! the satellite's URL and that code into a hub's node settings, and the
//! hub receives a bearer token that owns the `/api/node/*` surface — agent
//! runs, files, git, terminals and clones on this machine.
//!
//! The only state the satellite keeps is a small JSON file in
//! `~/.devinorium/satellite-state.json` holding its node id and the hashes
//! of issued tokens, so a restart does not break existing pairings. The
//! pairing code itself rotates on every boot and is never persisted.

mod clone;
mod files;
mod git;
mod runs;
mod terminal;

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, State};
use axum::http::StatusCode;
use axum::middleware::{from_fn_with_state, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::Deserialize;
use tokio::sync::{oneshot, Mutex, RwLock};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::trace::TraceLayer;

use crate::node::{
    generate_node_token, generate_pairing_code, hash_node_token, pairing_code_matches, NodeError,
    NodeInfo, PairRequest, PairResponse,
};
use crate::providers::{AskOutcome, PermissionOutcome};

/// A live provider run the hub may cancel.
pub struct NodeRun {
    pub cancel: Arc<AtomicBool>,
}

/// A pending permission/ask decision the hub resolves via `/api/node/callback`.
pub enum PendingCallback {
    Permission(oneshot::Sender<PermissionOutcome>),
    Ask(oneshot::Sender<AskOutcome>),
}

/// Satellite-side shared state. Everything is in memory except the identity
/// file; losing it only means re-pairing.
pub struct SatelliteState {
    pub home_dir: PathBuf,
    pub node_name: String,
    pub max_body_bytes: usize,
    /// This boot's pairing code, shown in the startup banner. Consumed by
    /// the first successful pair; a new code needs a restart.
    pub pairing_code: RwLock<String>,
    pub node_id: String,
    /// SHA-256 hashes of issued node tokens.
    tokens: RwLock<std::collections::HashSet<String>>,
    /// Runs in flight, keyed by hub-supplied run id.
    pub runs: Mutex<HashMap<String, NodeRun>>,
    /// Open permission/ask requests awaiting a hub decision.
    pub pending: Mutex<HashMap<String, PendingCallback>>,
    pub git: Arc<crate::git::GitService>,
    pub terminal_manager: crate::terminal::manager::TerminalManager,
    /// Where the identity file lives.
    state_file: PathBuf,
    /// Failed pairing attempts per client address.
    pair_attempts: Mutex<HashMap<IpAddr, PairAttempts>>,
}

struct PairAttempts {
    fails: u32,
    locked_until: Option<Instant>,
}

/// Maximum failed pair attempts before a short lockout. The code space is
/// huge (~60 bits); this exists so an exposed satellite cannot be sprayed
/// at meaningful speed.
const PAIR_MAX_FAILS: u32 = 10;
const PAIR_LOCKOUT: Duration = Duration::from_secs(60);
const PAIR_ATTEMPTS_CAP: usize = 1024;

/// Run bodies carry base64 attachments (the hub allows 64 MiB per turn,
/// which is ~85 MiB on the wire); give run routes a ceiling that fits a
/// full pack plus the rest of the request.
const RUN_BODY_LIMIT: usize = 128 * 1024 * 1024;

/// The identity file: `~/.devinorium/satellite-state.json`.
fn default_state_file(home_dir: &std::path::Path) -> PathBuf {
    home_dir.join(".devinorium").join("satellite-state.json")
}

#[derive(Deserialize)]
struct StateFile {
    node_id: String,
    #[serde(default)]
    tokens: Vec<String>,
}

impl SatelliteState {
    /// Load or create the node identity and start a fresh pairing code.
    pub async fn load(cfg: &crate::config::Config) -> Arc<Self> {
        let state_file = default_state_file(&cfg.home_dir);
        let saved: Option<StateFile> = match tokio::fs::read(&state_file).await {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| {
                tracing::warn!(error = %e, "satellite state file unreadable; starting fresh identity")
            }).ok(),
            Err(_) => None,
        };
        let saved = saved.filter(|s| !s.node_id.is_empty());
        let (node_id, tokens) = match &saved {
            Some(s) => (s.node_id.clone(), s.tokens.iter().cloned().collect()),
            None => (
                uuid::Uuid::new_v4().to_string(),
                std::collections::HashSet::new(),
            ),
        };
        let state = Arc::new(Self {
            home_dir: cfg.home_dir.clone(),
            node_name: cfg.display_node_name(),
            max_body_bytes: cfg.max_body_bytes,
            pairing_code: RwLock::new(generate_pairing_code()),
            node_id,
            tokens: RwLock::new(tokens),
            runs: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            git: Arc::new(crate::git::GitService::new()),
            terminal_manager: crate::terminal::manager::TerminalManager::new(
                Duration::from_secs(30 * 60),
                Duration::from_secs(60),
            ),
            state_file,
            pair_attempts: Mutex::new(HashMap::new()),
        });
        if saved.is_none() {
            state.persist().await;
        }
        state
    }

    /// Write the identity file. Best-effort: the node still works without
    /// it, restarts just lose pairings.
    pub async fn persist(&self) {
        let Some(parent) = self.state_file.parent() else {
            return;
        };
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            tracing::warn!(error = %e, "failed to create satellite state dir");
            return;
        }
        let tokens: Vec<String> = self.tokens.read().await.iter().cloned().collect();
        let body = serde_json::json!({
            "node_id": self.node_id,
            "tokens": tokens,
        });
        let tmp = self.state_file.with_extension("json.tmp");
        match tokio::fs::write(&tmp, body.to_string()).await {
            Ok(()) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ =
                        tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
                            .await;
                }
                let _ = tokio::fs::rename(&tmp, &self.state_file).await;
            }
            Err(e) => tracing::warn!(error = %e, "failed to write satellite state file"),
        }
    }

    pub async fn has_token(&self, token: &str) -> bool {
        self.tokens.read().await.contains(&hash_node_token(token))
    }

    /// Mint a fresh node token, store its hash, and persist the identity
    /// file. Returns the raw token, the only time it exists in plaintext.
    pub async fn issue_token(&self) -> String {
        let token = generate_node_token();
        self.tokens.write().await.insert(hash_node_token(&token));
        self.persist().await;
        token
    }
}

fn node_error(status: StatusCode, kind: &str, msg: impl Into<String>) -> Response {
    (status, Json(NodeError::new(kind, msg))).into_response()
}

pub(crate) fn bad_request(msg: impl Into<String>) -> Response {
    node_error(StatusCode::BAD_REQUEST, "bad_request", msg)
}

pub(crate) fn internal(e: impl std::fmt::Display) -> Response {
    node_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal",
        format!("{e}"),
    )
}

/// Bearer-token check applied to every `/api/node/*` route except
/// `info`/`pair`. A token maps to nothing less than owner-level control of
/// this machine, so unknown or missing credentials get a flat 401 with no
/// detail.
async fn node_auth(
    State(state): State<Arc<SatelliteState>>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    let token = crate::auth::session::extract_bearer_token(&req);
    match token {
        Some(t) if state.has_token(&t).await => {
            if let Some(u) = req
                .headers()
                .get(crate::federation::PROXY_USER_HEADER)
                .and_then(|v| v.to_str().ok())
            {
                tracing::debug!(user = %u, "node call on behalf of hub user");
            }
            next.run(req).await
        }
        _ => node_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "invalid node token",
        ),
    }
}

/// Build the satellite router: `info`/`pair` public, everything else behind
/// the node-token middleware.
pub fn build_app(state: Arc<SatelliteState>) -> Router {
    let public = Router::new()
        .route("/api/node/info", get(info))
        .route("/api/node/pair", post(pair))
        .route_layer(RequestBodyLimitLayer::new(16 * 1024));

    // Run requests carry base64 attachments and stay open for the whole
    // turn; they get a dedicated ceiling rather than the generic one so a
    // normal-sized prompt pack never trips the upload limit.
    let runs = runs::router()
        .route_layer(from_fn_with_state(state.clone(), node_auth))
        .route_layer(RequestBodyLimitLayer::new(RUN_BODY_LIMIT));

    let protected = Router::new()
        .merge(files::router())
        .merge(git::router())
        .merge(terminal::router())
        .merge(clone::router())
        .route_layer(from_fn_with_state(state.clone(), node_auth))
        .route_layer(RequestBodyLimitLayer::new(state.max_body_bytes));

    Router::new()
        .merge(public)
        .merge(protected)
        .merge(runs)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn info(State(state): State<Arc<SatelliteState>>) -> impl IntoResponse {
    Json(NodeInfo {
        satellite: true,
        node_id: state.node_id.clone(),
        name: state.node_name.clone(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    })
}

/// Exchange the printed pairing code for a node token. Failed attempts are
/// counted per source address and lock out after [`PAIR_MAX_FAILS`].
async fn pair(
    State(state): State<Arc<SatelliteState>>,
    addr: ConnectInfo<std::net::SocketAddr>,
    Json(req): Json<PairRequest>,
) -> Response {
    let ip = addr.ip();
    {
        let attempts = state.pair_attempts.lock().await;
        if let Some(a) = attempts.get(&ip) {
            if let Some(until) = a.locked_until {
                if Instant::now() < until {
                    return node_error(
                        StatusCode::TOO_MANY_REQUESTS,
                        "rate_limited",
                        "too many failed pairing attempts",
                    );
                }
            }
        }
    }

    let issued_code = state.pairing_code.read().await.clone();
    if !pairing_code_matches(&issued_code, &req.code) {
        let mut attempts = state.pair_attempts.lock().await;
        // Bound the map: a scanner could otherwise grow it one entry per
        // spoofed source address.
        if attempts.len() >= PAIR_ATTEMPTS_CAP {
            let now = Instant::now();
            attempts.retain(|_, a| a.locked_until.is_some_and(|t| t > now));
            if attempts.len() >= PAIR_ATTEMPTS_CAP {
                attempts.clear();
            }
        }
        let entry = attempts.entry(ip).or_insert(PairAttempts {
            fails: 0,
            locked_until: None,
        });
        entry.fails += 1;
        if entry.fails >= PAIR_MAX_FAILS {
            entry.locked_until = Some(Instant::now() + PAIR_LOCKOUT);
        }
        tracing::warn!(%ip, "rejected pairing attempt with wrong code");
        if issued_code.is_empty() {
            return node_error(
                StatusCode::GONE,
                "consumed",
                "pairing code already used; restart the satellite for a new one",
            );
        }
        return node_error(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "invalid pairing code",
        );
    }

    // The printed code pairs exactly one hub; a second hub needs a fresh
    // boot (and a fresh code).
    state.pairing_code.write().await.clear();

    let token = state.issue_token().await;
    tracing::info!(%ip, "hub paired with this satellite");

    Json(PairResponse {
        node_id: state.node_id.clone(),
        name: state.node_name.clone(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        token,
    })
    .into_response()
}

/// Satellite entry point called from `main` when `DEVINORIUM_SATELLITE=1`.
pub async fn run(cfg: crate::config::Config) -> anyhow::Result<()> {
    let state = SatelliteState::load(&cfg).await;
    let app = build_app(state.clone());

    let bind = cfg.bind_addr();
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    let addr = listener.local_addr()?;

    let code = state.pairing_code.read().await.clone();
    let name = &state.node_name;
    eprintln!();
    eprintln!("Devinorium satellite ({name}) listening on {addr}");
    eprintln!();
    eprintln!("  Pairing code: {code}");
    eprintln!();
    eprintln!("  In your main instance go to Settings -> Nodes, enter");
    eprintln!("  this server's URL and the code above, then pair.");
    eprintln!();
    tracing::info!(%addr, "satellite ready; pair it from a hub");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;
    Ok(())
}
