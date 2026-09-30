//! Capability tokens that let a running agent drive a machine without the
//! VNC password ever leaving the server.
//!
//! When a send references machines the run mints a grant listing those
//! machine ids; the agent presents the token to the `/api/machine-control`
//! endpoints. Grants live only in memory, are scoped to the referenced
//! machines, and are revoked when the run ends. `GRANT_TTL` is only a
//! backstop for grants that outlive their guard: while a run holds its
//! [`GrantGuard`] a keeper task renews the grant, so a token stays valid
//! for the whole run however long that takes.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::time::Instant;

const GRANT_TTL: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Debug)]
struct Grant {
    user_id: i64,
    machine_ids: Vec<i64>,
    expires_at: Instant,
}

/// A snapshot of a live grant returned by [`MachineGrants::lookup`].
#[derive(Debug, Clone)]
pub struct GrantInfo {
    pub user_id: i64,
    pub machine_ids: Vec<i64>,
}

#[derive(Clone)]
pub struct MachineGrants {
    inner: Arc<Mutex<HashMap<String, Grant>>>,
    ttl: Duration,
}

impl Default for MachineGrants {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            ttl: GRANT_TTL,
        }
    }
}

impl MachineGrants {
    pub fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    fn with_ttl(ttl: Duration) -> Self {
        assert!(ttl > Duration::ZERO);
        Self {
            ttl,
            ..Self::default()
        }
    }

    /// Mint a token for `machine_ids`. Empty lists produce no token.
    pub fn create(&self, user_id: i64, machine_ids: Vec<i64>) -> Option<String> {
        if machine_ids.is_empty() {
            return None;
        }
        let mut bytes = [0u8; 32];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut bytes);
        let token = format!("mc_{}", hex::encode(bytes));
        let grant = Grant {
            user_id,
            machine_ids,
            expires_at: Instant::now() + self.ttl,
        };
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(token.clone(), grant);
        Some(token)
    }

    /// The grant for `token`, or `None` when it is unknown or expired.
    /// The caller checks `machine_ids` membership itself so it can tell
    /// "bad token" apart from "token that does not cover this machine".
    pub fn lookup(&self, token: &str) -> Option<GrantInfo> {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let grant = map.get(token)?;
        if grant.expires_at <= Instant::now() {
            map.remove(token);
            return None;
        }
        Some(GrantInfo {
            user_id: grant.user_id,
            machine_ids: grant.machine_ids.clone(),
        })
    }

    /// Push a live grant's expiry out by a full TTL. Returns false when
    /// the token is unknown or already dead — dropping the dead entry —
    /// so a keeper loop knows to stop; a dead grant is never resurrected.
    pub fn renew(&self, token: &str) -> bool {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        match map.get_mut(token) {
            Some(grant) if grant.expires_at > Instant::now() => {
                grant.expires_at = Instant::now() + self.ttl;
                true
            }
            Some(_) => {
                map.remove(token);
                false
            }
            None => false,
        }
    }

    pub fn revoke(&self, token: &str) {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(token);
    }
}

/// Revokes its token on drop; held for the duration of a run. While held
/// it keeps the grant renewed well inside its TTL, so the token outlives
/// `GRANT_TTL` whenever the run does.
pub(crate) struct GrantGuard {
    grants: MachineGrants,
    token: String,
    keeper: Option<tokio::task::JoinHandle<()>>,
}

impl GrantGuard {
    pub(crate) fn new(grants: MachineGrants, token: String) -> Self {
        let keeper = match tokio::runtime::Handle::try_current() {
            Ok(handle) => Some(handle.spawn({
                let grants = grants.clone();
                let token = token.clone();
                async move {
                    // Renew straight away so a bogus token never parks a
                    // keeper, then again every half TTL while the run lives.
                    while grants.renew(&token) {
                        tokio::time::sleep(grants.ttl / 2).await;
                    }
                }
            })),
            Err(_) => {
                // Outside a tokio runtime (unit tests) there is nowhere to
                // run a keeper; the grant simply keeps its plain TTL.
                tracing::warn!("machine grant has no keeper: no tokio runtime");
                None
            }
        };
        Self {
            grants,
            token,
            keeper,
        }
    }
}

impl Drop for GrantGuard {
    fn drop(&mut self) {
        self.grants.revoke(&self.token);
        if let Some(keeper) = self.keeper.take() {
            keeper.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grant_scopes_to_listed_machines() {
        let grants = MachineGrants::new();
        let token = grants.create(7, vec![1, 2]).unwrap();
        let info = grants.lookup(&token).unwrap();
        assert_eq!(info.user_id, 7);
        assert_eq!(info.machine_ids, [1, 2]);
        assert!(grants.lookup("mc_nope").is_none());
    }

    #[test]
    fn empty_grant_mints_nothing() {
        assert!(MachineGrants::new().create(1, vec![]).is_none());
    }

    #[test]
    fn revoke_invalidates_token() {
        let grants = MachineGrants::new();
        let token = grants.create(1, vec![1]).unwrap();
        grants.revoke(&token);
        assert!(grants.lookup(&token).is_none());
    }

    #[test]
    fn guard_revokes_on_drop() {
        let grants = MachineGrants::new();
        let token = grants.create(1, vec![1]).unwrap();
        {
            let _guard = GrantGuard::new(grants.clone(), token.clone());
        }
        assert!(grants.lookup(&token).is_none());
    }

    #[tokio::test]
    async fn grant_expires_without_a_guard() {
        let grants = MachineGrants::with_ttl(Duration::from_millis(60));
        let token = grants.create(1, vec![1]).unwrap();
        tokio::time::sleep(Duration::from_millis(120)).await;
        assert!(grants.lookup(&token).is_none());
        assert!(grants.inner.lock().unwrap().is_empty());
    }

    #[test]
    fn renew_pushes_expiry_out() {
        let grants = MachineGrants::with_ttl(Duration::from_secs(60));
        let token = grants.create(1, vec![1]).unwrap();
        let before = grants.inner.lock().unwrap()[&token].expires_at;
        std::thread::sleep(Duration::from_millis(5));
        assert!(grants.renew(&token));
        let after = grants.inner.lock().unwrap()[&token].expires_at;
        assert!(after > before);
    }

    #[tokio::test]
    async fn renew_refuses_unknown_and_dead_tokens() {
        let grants = MachineGrants::with_ttl(Duration::from_millis(40));
        assert!(!grants.renew("mc_nope"));
        let token = grants.create(1, vec![1]).unwrap();
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert!(!grants.renew(&token), "dead grants stay dead");
        assert!(grants.inner.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn keeper_holds_grant_for_the_whole_run() {
        let grants = MachineGrants::with_ttl(Duration::from_secs(2));
        let token = grants.create(1, vec![1]).unwrap();
        let guard = GrantGuard::new(grants.clone(), token.clone());
        // Well past the plain TTL; the keeper must have renewed the grant.
        tokio::time::sleep(Duration::from_millis(4500)).await;
        assert!(grants.lookup(&token).is_some());
        drop(guard);
        assert!(grants.lookup(&token).is_none());
        assert!(grants.inner.lock().unwrap().is_empty());
    }
}
