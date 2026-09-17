//! Capability tokens that let a running agent drive a machine without the
//! VNC password ever leaving the server.
//!
//! When a send references machines the run mints a grant listing those
//! machine ids; the agent presents the token to the `/api/machine-control`
//! endpoints. Grants live only in memory, are scoped to the referenced
//! machines, expire after `GRANT_TTL`, and are revoked when the run ends.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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

#[derive(Clone, Default)]
pub struct MachineGrants {
    inner: Arc<Mutex<HashMap<String, Grant>>>,
}

impl MachineGrants {
    pub fn new() -> Self {
        Self::default()
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
            expires_at: Instant::now() + GRANT_TTL,
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

    pub fn revoke(&self, token: &str) {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(token);
    }
}

/// Revokes its token on drop; held for the duration of a run.
pub(crate) struct GrantGuard {
    grants: MachineGrants,
    token: String,
}

impl GrantGuard {
    pub(crate) fn new(grants: MachineGrants, token: String) -> Self {
        Self { grants, token }
    }
}

impl Drop for GrantGuard {
    fn drop(&mut self) {
        self.grants.revoke(&self.token);
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
}
