//! Web Push delivery for run lifecycle events.
//!
//! `PushService` owns the instance VAPID keypair (persisted in
//! `server_settings` so subscriptions survive restarts) and sends RFC 8291
//! aes128gcm-encrypted pushes with RFC 8292 VAPID auth. `dispatch` listens to
//! the thread runner's lifecycle feed and turns transitions into pushes.

pub mod crypto;
pub mod dispatch;
mod strings;

use std::sync::Arc;

use anyhow::Result;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::Serialize;

use crate::db::push::PushSubscriptionRow;
use crate::db::Db;

pub use dispatch::spawn_dispatch;

/// server_settings key holding the JSON-serialized VAPID keypair.
const VAPID_KEYS_SETTING: &str = "vapid_keys";

/// What a push is about; drives the payload `kind`, the notification tag,
/// and the localized title/body the service worker renders.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushKind {
    Completed,
    Failed,
    Permission,
    Ask,
    Test,
}

impl PushKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            PushKind::Completed => "completed",
            PushKind::Failed => "failed",
            PushKind::Permission => "permission",
            PushKind::Ask => "ask",
            PushKind::Test => "test",
        }
    }
}

/// A push that reached a device (or would have).
#[derive(Debug, Serialize)]
struct PushPayload<'a> {
    v: u8,
    kind: &'a str,
    title: &'a str,
    body: &'a str,
    tag: &'a str,
    thread_id: &'a str,
}

struct Inner {
    db: Db,
    http: reqwest::Client,
    vapid: crypto::VapidKeys,
    /// RFC 8292 `sub` contact URI (mailto: or https:).
    subject: String,
}

/// Web Push sender. `disabled()` yields a no-op handle so tests and
/// embedders that never init it do not need keys.
#[derive(Clone)]
pub struct PushService {
    inner: Option<Arc<Inner>>,
}

/// True for addresses on the public internet. A push endpoint is always a
/// public relay: private, loopback, link-local, CGNAT and other internal
/// ranges must never be POSTed to, or a registered subscription becomes an
/// SSRF probe into the network the server sits on.
fn public_ip(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(ip) => {
            !(ip.is_private()
                || ip.is_loopback()
                || ip.is_link_local()
                || ip.is_unspecified()
                || ip.is_broadcast()
                || ip.is_multicast()
                || ip.is_documentation()
                // 0/8 "this network" beyond just 0.0.0.0.
                || ip.octets()[0] == 0
                // 192.0.0/24 IETF protocol assignments.
                || (ip.octets()[0] == 192 && ip.octets()[1] == 0 && ip.octets()[2] == 0)
                // 100.64/10 CGNAT.
                || (ip.octets()[0] == 100 && ip.octets()[1] & 0xC0 == 0x40)
                // 198.18/15 benchmarking.
                || (ip.octets()[0] == 198 && ip.octets()[1] & 0xFE == 18)
                // 240/4 reserved.
                || ip.octets()[0] >= 240)
        }
        std::net::IpAddr::V6(ip) => {
            let seg = ip.segments();
            !(ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_multicast()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
                || ip
                    .to_ipv4_mapped()
                    .is_some_and(|v4| !public_ip(std::net::IpAddr::V4(v4)))
                // ::/96 v4-compatible, deprecated but still embeds a v4.
                || (seg[..6] == [0, 0, 0, 0, 0, 0] && seg[6] != 0)
                // 64:ff9b::/96 and 64:ff9b:1::/48 NAT64 embed a v4.
                || (seg[0] == 0x64 && seg[1] == 0xff9b)
                // 2002::/16 6to4 embeds a v4; 2001::/32 is Teredo.
                || seg[0] == 0x2002
                || (seg[0] == 0x2001 && seg[1] == 0))
        }
    }
}

/// Check that the endpoint is an https URL whose host can only be a public
/// push service: literal IPs must be public, and names must resolve to
/// nothing but public addresses. Runs at subscribe time and again before
/// every send, so a rebound DNS name or a row stored before the check
/// existed cannot reach an internal address.
fn unbracket_host(host: &str) -> &str {
    host.strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host)
}

pub(crate) async fn endpoint_host_is_public(endpoint: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(endpoint) else {
        return false;
    };
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str().map(|h| h.trim_end_matches('.')) else {
        return false;
    };
    let host = unbracket_host(host);
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return public_ip(ip);
    }
    // Anything else holding a colon is a v6 literal in some spelling the
    // parser did not recognize; names never contain one.
    if host.contains(':') {
        return false;
    }
    let port = url.port_or_known_default().unwrap_or(443);
    let resolved = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tokio::net::lookup_host((host, port)),
    )
    .await;
    match resolved {
        Ok(Ok(addrs)) => {
            let ips: Vec<_> = addrs.map(|a| a.ip()).collect();
            !ips.is_empty() && ips.iter().all(|ip| public_ip(*ip))
        }
        _ => false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SendOutcome {
    Delivered,
    /// 404/410 — the endpoint is dead and the row should be pruned.
    Gone,
    Failed,
}

impl PushService {
    /// A service that drops every send. Used by tests that never init push.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// Load the VAPID keypair from `server_settings`, generating and
    /// persisting a fresh one on first run or after corruption.
    pub async fn new(db: Db, subject: String) -> Result<Self> {
        let vapid = match Self::load_keys(&db).await {
            Ok(Some(keys)) => keys,
            Ok(None) => {
                let keys = crypto::VapidKeys::generate()?;
                Self::store_keys(&db, &keys).await?;
                keys
            }
            Err(e) => {
                tracing::warn!("stored vapid keys unusable ({e}); regenerating");
                let keys = crypto::VapidKeys::generate()?;
                Self::store_keys(&db, &keys).await?;
                keys
            }
        };
        Ok(Self {
            inner: Some(Arc::new(Inner {
                db,
                http: reqwest::Client::builder()
                    .timeout(std::time::Duration::from_secs(15))
                    // A redirect could bounce a send at an internal
                    // address the endpoint check was meant to exclude.
                    .redirect(reqwest::redirect::Policy::none())
                    .user_agent(concat!("devinorium/", env!("CARGO_PKG_VERSION")))
                    .build()?,
                vapid,
                subject,
            })),
        })
    }

    async fn load_keys(db: &Db) -> Result<Option<crypto::VapidKeys>> {
        let Some(raw) = db.get_server_setting(VAPID_KEYS_SETTING).await? else {
            return Ok(None);
        };
        let stored: serde_json::Value = serde_json::from_str(&raw)?;
        let pkcs8 = stored["pkcs8"]
            .as_str()
            .and_then(|s| URL_SAFE_NO_PAD.decode(s).ok())
            .ok_or_else(|| anyhow::anyhow!("missing pkcs8"))?;
        Ok(Some(crypto::VapidKeys::from_pkcs8(&pkcs8)?))
    }

    async fn store_keys(db: &Db, keys: &crypto::VapidKeys) -> Result<()> {
        let raw = serde_json::json!({
            "pkcs8": URL_SAFE_NO_PAD.encode(&keys.pkcs8),
        })
        .to_string();
        db.set_server_setting(VAPID_KEYS_SETTING, &raw).await
    }

    pub fn enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// The `applicationServerKey` the frontend subscribes with, base64url.
    pub fn vapid_public_key(&self) -> Option<String> {
        self.inner
            .as_ref()
            .map(|i| URL_SAFE_NO_PAD.encode(&i.vapid.public_key))
    }

    /// Push a run event to every subscription `user_id` owns. Returns how
    /// many endpoints accepted the message. Dead endpoints are pruned.
    pub async fn send_to_user(
        &self,
        user_id: i64,
        kind: PushKind,
        thread_id: &str,
        thread_title: &str,
    ) -> usize {
        let Some(inner) = &self.inner else { return 0 };
        let subs = match inner.db.push_subscriptions_for_user(user_id).await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = %e, "failed to load push subscriptions");
                return 0;
            }
        };
        if subs.is_empty() {
            return 0;
        }
        let sends = subs.iter().map(|sub| {
            let (title, body) = strings::render(kind, &sub.lang, thread_title);
            let payload = serde_json::to_string(&PushPayload {
                v: 1,
                kind: kind.as_str(),
                title: &title,
                body: &body,
                tag: &format!("devinorium-{}-{}", kind.as_str(), thread_id),
                thread_id,
            })
            .unwrap_or_else(|_| "{}".into());
            async move {
                (
                    sub.endpoint.clone(),
                    self.send_one(sub, &payload, kind).await,
                )
            }
        });
        let mut delivered = 0;
        for (endpoint, outcome) in futures::future::join_all(sends).await {
            match outcome {
                SendOutcome::Delivered => delivered += 1,
                SendOutcome::Gone => {
                    if let Err(e) = inner.db.prune_push_endpoint(&endpoint).await {
                        tracing::warn!(error = %e, "failed to prune push subscription");
                    }
                }
                SendOutcome::Failed => {}
            }
        }
        delivered
    }

    /// Send a test push to all of the user's subscriptions.
    pub async fn send_test(&self, user_id: i64) -> usize {
        self.send_to_user(user_id, PushKind::Test, "", "").await
    }

    async fn send_one(
        &self,
        sub: &PushSubscriptionRow,
        payload: &str,
        kind: PushKind,
    ) -> SendOutcome {
        let Some(inner) = &self.inner else {
            return SendOutcome::Failed;
        };
        if !endpoint_host_is_public(&sub.endpoint).await {
            tracing::warn!(endpoint = %sub.endpoint, "push endpoint is not a public address; skipping");
            return SendOutcome::Failed;
        }
        let body = match crypto::encrypt_payload(&sub.p256dh, &sub.auth, payload.as_bytes()) {
            Ok(b) => b,
            Err(e) => {
                tracing::warn!(endpoint = %sub.endpoint, error = %e, "push encryption failed");
                return SendOutcome::Failed;
            }
        };
        let auth = match crypto::vapid_authorization(&sub.endpoint, &inner.subject, &inner.vapid) {
            Ok(a) => a,
            Err(e) => {
                tracing::warn!(endpoint = %sub.endpoint, error = %e, "vapid signing failed");
                return SendOutcome::Failed;
            }
        };
        let urgency = match kind {
            PushKind::Permission | PushKind::Ask => "high",
            _ => "normal",
        };
        let resp = inner
            .http
            .post(&sub.endpoint)
            .header("Authorization", auth)
            .header("TTL", "86400")
            .header("Urgency", urgency)
            .header("Content-Encoding", "aes128gcm")
            .header("Content-Type", "application/octet-stream")
            .body(body)
            .send()
            .await;
        match resp {
            Ok(r) if r.status().is_success() => SendOutcome::Delivered,
            Ok(r) => {
                let status = r.status().as_u16();
                if status == 404 || status == 410 {
                    tracing::info!(endpoint = %sub.endpoint, "push endpoint gone; pruning");
                    SendOutcome::Gone
                } else {
                    // A 3xx lands here because redirects are disabled: a
                    // legit push service does not redirect POSTs, and the
                    // row is retried rather than pruned.
                    tracing::warn!(endpoint = %sub.endpoint, status, "push rejected");
                    SendOutcome::Failed
                }
            }
            Err(e) => {
                tracing::warn!(endpoint = %sub.endpoint, error = %e, "push send failed");
                SendOutcome::Failed
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn internal_endpoints_are_rejected() {
        for ep in [
            "https://127.0.0.1/push",
            "https://10.0.0.1/",
            "https://192.168.1.1:8080/p",
            "https://169.254.169.254/latest/meta-data",
            "https://172.16.5.5/",
            "https://100.64.3.7/",
            "https://198.18.0.1/",
            "https://240.1.2.3/",
            "https://0.0.0.0/",
            "https://0.8.8.8/",
            "https://192.0.0.7/",
            "https://[::1]/",
            "https://[fd00::1]/",
            "https://[fe80::1]/",
            "https://[::ffff:10.0.0.1]/",
            "https://[::10.0.0.1]/",
            "https://[64:ff9b::a00:1]/",
            "https://[2002:a00:1::1]/",
            "https://[2001::5efc:a00:1]/",
            // localhost only resolves to loopback.
            "https://localhost/",
            "https://no-such-host.invalid/",
            // Anything but https leaks the VAPID JWT in plaintext.
            "http://8.8.8.8/x",
            "ftp://8.8.8.8/x",
            "not a url",
            "https://",
        ] {
            assert!(
                !endpoint_host_is_public(ep).await,
                "{ep} should be rejected"
            );
        }
    }

    #[tokio::test]
    async fn public_literal_endpoints_pass() {
        // Literal IPs need no DNS at all.
        for ep in ["https://8.8.8.8/push", "https://[2606:4700:4700::1111]/x"] {
            assert!(endpoint_host_is_public(ep).await, "{ep} should pass");
        }
    }
}
