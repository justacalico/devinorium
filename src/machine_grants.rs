//! Capability tokens that let a running agent drive a machine without the
//! VNC password ever leaving the server.
//!
//! When a send references machines the run mints a grant listing those
//! machine ids; the agent presents the token to the `/api/machine-control`
//! endpoints. Grants live only in memory, are scoped to the referenced
//! machines, and expire after [`GRANT_TTL`]: tokens surface verbatim in
//! the transcript an agent runs, so a leaked token must not stay live
//! forever. A server restart clears the whole map.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How long a minted grant stays usable. Long enough to cover an
/// agent pausing on a permission prompt, short enough that a token
/// recorded into an old transcript or a public share goes stale.
const GRANT_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Bound on live grants; expiries are swept when inserts hit this size.
const GRANT_TABLE_CAP: usize = 4096;

#[derive(Debug)]
struct Grant {
    user_id: i64,
    machine_ids: Vec<i64>,
    created_at: Instant,
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
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if map.len() >= GRANT_TABLE_CAP {
            let now = Instant::now();
            map.retain(|_, g| now.duration_since(g.created_at) < GRANT_TTL);
            while map.len() >= GRANT_TABLE_CAP {
                match map
                    .iter()
                    .min_by_key(|(_, g)| g.created_at)
                    .map(|(k, _)| k.clone())
                {
                    Some(oldest) => {
                        map.remove(&oldest);
                    }
                    None => break,
                }
            }
        }
        map.insert(
            token.clone(),
            Grant {
                user_id,
                machine_ids,
                created_at: Instant::now(),
            },
        );
        Some(token)
    }

    /// The grant for `token`, or `None` when it is unknown or expired.
    /// Lookup does not consume the grant: the agent may reuse it within
    /// its lifetime. The caller checks `machine_ids` membership itself so
    /// it can tell "bad token" apart from "token that does not cover this
    /// machine".
    pub fn lookup(&self, token: &str) -> Option<GrantInfo> {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        match map.get(token) {
            Some(grant) if Instant::now().duration_since(grant.created_at) < GRANT_TTL => {
                Some(GrantInfo {
                    user_id: grant.user_id,
                    machine_ids: grant.machine_ids.clone(),
                })
            }
            Some(_) => {
                map.remove(token);
                None
            }
            None => None,
        }
    }
}

/// Replace machine-grant tokens in `text` with a placeholder. Transcript
/// parts record the `curl -H "Authorization: Bearer mc_..."` commands the
/// agent ran; anything shown to someone other than the grant owner must
/// not carry a live credential.
pub fn redact_tokens(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(idx) = rest.find("mc_") {
        let after = &rest[idx + 3..];
        let hex_len = after.chars().take_while(|c| c.is_ascii_hexdigit()).count();
        if hex_len >= 32 {
            out.push_str(&rest[..idx]);
            out.push_str("mc_[redacted]");
            rest = &after[hex_len..];
        } else {
            out.push_str(&rest[..idx + 3]);
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// Apply [`redact_tokens`] to every string inside a JSON value.
pub fn redact_value(v: &mut serde_json::Value) {
    match v {
        serde_json::Value::String(s) => *s = redact_tokens(s),
        serde_json::Value::Array(items) => items.iter_mut().for_each(redact_value),
        serde_json::Value::Object(map) => map.values_mut().for_each(redact_value),
        _ => {}
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
    fn grants_survive_repeated_lookups() {
        let grants = MachineGrants::new();
        let token = grants.create(1, vec![1]).unwrap();
        for _ in 0..3 {
            assert!(grants.lookup(&token).is_some());
        }
    }

    #[test]
    fn expired_grants_stop_resolving() {
        let grants = MachineGrants::new();
        let token = grants.create(1, vec![1]).unwrap();
        grants
            .inner
            .lock()
            .unwrap()
            .get_mut(&token)
            .unwrap()
            .created_at = Instant::now() - GRANT_TTL - Duration::from_secs(1);
        assert!(grants.lookup(&token).is_none());
        assert!(grants.inner.lock().unwrap().is_empty());
    }

    #[test]
    fn grant_table_stays_bounded() {
        let grants = MachineGrants::new();
        for _ in 0..GRANT_TABLE_CAP + 10 {
            grants.create(1, vec![1]).unwrap();
        }
        assert!(grants.inner.lock().unwrap().len() <= GRANT_TABLE_CAP);
    }

    #[test]
    fn redact_strips_grant_tokens_only() {
        let token = format!("mc_{}", "a".repeat(64));
        let text = format!("curl -H 'Authorization: Bearer {token}' http://x/mc_short");
        let out = redact_tokens(&text);
        assert!(out.contains("Bearer mc_[redacted]"));
        assert!(out.contains("mc_short"));
        assert!(!out.contains(&token));
        assert_eq!(redact_tokens("no tokens here"), "no tokens here");
    }
}
