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

/// Header set by a hub on proxied requests naming the hub user who made
/// the call, so satellite logs can attribute actions. Only meaningful when
/// set by a trusted hub; inbound copies are stripped at the boundary.
pub const PROXY_USER_HEADER: &str = "x-devinorium-proxy-user";

/// Hard cap on how many times a request may be proxied between nodes.
pub const MAX_PROXY_HOPS: u32 = 4;

/// server_settings key for the satellite's self-issued stable node id.
const NODE_ID_KEY: &str = "federation_node_id";

/// Normalize and validate a node base URL: it must be a plain http(s)
/// origin with no userinfo, path, query, or fragment, since proxied paths
/// are appended verbatim. Anything reachable from the hub is allowed by
/// design — the shared token is the gate, and LAN addresses are the point
/// of the feature. Shared by hub-side registration checks and satellite
/// config validation so both ends agree on what is legal.
pub fn clean_node_base_url(raw: &str) -> Option<String> {
    let url = raw.trim().trim_end_matches('/');
    if url.len() > 512 {
        return None;
    }
    let parsed = reqwest::Url::parse(url).ok()?;
    let ok_scheme = matches!(parsed.scheme(), "http" | "https");
    let bare = parsed.path() == "/" || parsed.path().is_empty();
    if !ok_scheme
        || parsed.host_str().is_none()
        || !bare
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return None;
    }
    Some(url.to_string())
}

/// Build the HTTP client shared by satellite registration and the hub's
/// request proxying. There is deliberately no overall timeout: SSE message
/// streams proxied through the hub stay open indefinitely. The connect
/// timeout is enough to fail dead nodes quickly.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("federation http client")
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
    if state.config.dev_mode {
        // A dev instance has a throwaway in-memory database; registering it
        // would leave a permanently-offline ghost node on the hub.
        tracing::warn!("federation: DEVINORIUM_HUB_URL ignored in dev mode");
        return None;
    }
    Some(tokio::spawn(async move {
        let mut self_id: Option<String> = None;
        loop {
            if self_id.is_none() {
                match node_id(&state.db).await {
                    Ok(id) => self_id = Some(id),
                    Err(e) => {
                        tracing::warn!("federation: failed to allocate node id, retrying: {e:#}");
                        tokio::time::sleep(HEARTBEAT_INTERVAL).await;
                        continue;
                    }
                }
            }
            if let Err(e) = register_once(&state, self_id.as_deref().unwrap_or_default()).await {
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
        anyhow::bail!(
            "hub returned {status}: {}",
            body.chars().take(200).collect::<String>()
        );
    }
    tracing::debug!(%hub, %base_url, "federation: registered with hub");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::clean_node_base_url;

    #[test]
    fn clean_node_base_url_accepts_plain_origins() {
        assert_eq!(
            clean_node_base_url("http://192.168.1.10:7878").as_deref(),
            Some("http://192.168.1.10:7878")
        );
        assert_eq!(
            clean_node_base_url("https://node.example.com/").as_deref(),
            Some("https://node.example.com")
        );
        assert!(clean_node_base_url(" http://host:1 ").is_some());
    }

    #[test]
    fn clean_node_base_url_rejects_non_origin_urls() {
        for bad in [
            "ftp://host",
            "http://",
            "not-a-url",
            "http://host/path",
            "http://host/?q=1",
            "http://host/#frag",
            "http://user@host",
            "http://user:pass@host",
        ] {
            assert_eq!(clean_node_base_url(bad), None, "{bad}");
        }
    }
}
