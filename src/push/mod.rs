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
