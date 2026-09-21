//! Hub/satellite federation.
//!
//! A hub accepts registrations from satellites and proxies API requests to
//! them; a satellite registers itself with a hub and answers proxied calls
//! authenticated by the shared `DEVINORIUM_FEDERATION_TOKEN`.
//!
//! Satellites push: each one POSTs `register` on a heartbeat, so a hub
//! never needs network reachability configured in advance and a node that
//! changes address heals on the next beat. The hub only needs the shared
//! token to gate who may join.

use std::time::Duration;

use serde::Serialize;

use crate::AppState;

/// How often a satellite re-registers with its hub.
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// A node counts as online while its last registration is this fresh. It
/// is ~3 missed heartbeats, so a brief network blip does not flap the UI.
pub const ONLINE_WINDOW: Duration = Duration::from_secs(90);

/// Header carried by proxied requests; incremented at every hop so a
/// misconfigured ring of hubs fails fast instead of looping forever.
pub const PROXY_HOP_HEADER: &str = "x-devinorium-proxy-hop";

/// Hard cap on how many times a request may be proxied between nodes.
pub const MAX_PROXY_HOPS: u32 = 4;

/// server_settings key for the satellite's self-issued stable node id.
const NODE_ID_KEY: &str = "federation_node_id";

/// Build the HTTP client shared by satellite registration and the hub's
/// request proxying. There is deliberately no overall timeout: SSE message
/// streams proxied through the hub stay open indefinitely. The connect
/// timeout is enough to fail dead nodes quickly.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

/// The node id this satellite advertises, generating and persisting one on
/// first use so re-registrations collapse onto the same hub-side row.
pub async fn node_id(db: &crate::db::Db) -> anyhow::Result<String> {
    if let Some(id) = db.get_server_setting(NODE_ID_KEY).await? {
        if !id.is_empty() {
            return Ok(id);
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    db.set_server_setting(NODE_ID_KEY, &id).await?;
    Ok(id)
}

/// Spawn the satellite registration loop when `DEVINORIUM_HUB_URL` is set.
/// The task runs until the process exits; registration failures are logged
/// and retried on the next beat rather than fatal.
///
/// Must be called after the listener is bound so a default node URL
/// derived from the bound address reports the real port.
pub fn spawn_satellite_loop(state: AppState) -> Option<tokio::task::JoinHandle<()>> {
    if !state.config.is_satellite() {
        return None;
    }
    Some(tokio::spawn(async move {
        let node_id = match node_id(&state.db).await {
            Ok(id) => id,
            Err(e) => {
                tracing::error!("federation: failed to allocate node id: {e:#}");
                return;
            }
        };
        loop {
            if let Err(e) = register_once(&state, &node_id).await {
                tracing::warn!("federation: registration with hub failed: {e:#}");
            }
            tokio::time::sleep(HEARTBEAT_INTERVAL).await;
        }
    }))
}

#[derive(Serialize)]
struct RegisterBody<'a> {
    id: &'a str,
    name: &'a str,
    base_url: &'a str,
    version: &'a str,
}

async fn register_once(state: &AppState, node_id: &str) -> anyhow::Result<()> {
    let cfg = &state.config;
    let hub = cfg.hub_url.as_deref().unwrap_or_default();
    let token = cfg.federation_token.as_deref().unwrap_or_default();
    let base_url = cfg
        .node_url
        .clone()
        .unwrap_or_else(|| state.agent_base_url());
    let name = cfg.display_node_name();

    let resp = state
        .http_client
        .post(format!("{hub}/api/federation/register"))
        .bearer_auth(token)
        .timeout(Duration::from_secs(15))
        .json(&RegisterBody {
            id: node_id,
            name: &name,
            base_url: &base_url,
            version: env!("CARGO_PKG_VERSION"),
        })
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        anyhow::bail!("hub returned {status}: {}", body.chars().take(200).collect::<String>());
    }
    tracing::debug!(%hub, %base_url, "federation: registered with hub");
    Ok(())
}
