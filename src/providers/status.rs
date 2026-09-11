//! Provider availability probing.
//!
//! Mirrors t3code's startup check: each registered provider's CLI is probed
//! with `<command> --version` once when the backend boots and the result is
//! cached briefly, so `GET /api/providers` can report which providers are
//! actually usable on this host and the frontend can grey out the ones whose
//! binary is missing.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;
use tokio::sync::Mutex;

/// How long a single `--version` probe may run before it is abandoned.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);
/// How long a probe result is reused before the binary is re-checked.
const STATUS_TTL: Duration = Duration::from_secs(60);

/// Availability of a provider's backing CLI on this host.
#[derive(Debug, Clone, Serialize)]
pub struct ProviderStatus {
    /// True when the command resolved and executed.
    pub installed: bool,
    /// Version reported by `--version`, when parseable.
    pub version: Option<String>,
    /// `"ready"` when usable, `"error"` when the binary is missing or broken.
    pub status: &'static str,
    /// Human-readable detail for errors, surfaced in pickers and tooltips.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl ProviderStatus {
    /// The provider is usable: its binary ran and answered `--version`.
    pub fn is_ready(&self) -> bool {
        self.installed && self.status == "ready"
    }

    /// Status for a provider that is assumed working without a probe — used
    /// for the app-level provider injected when no command is configured.
    pub fn ready() -> Self {
        Self {
            installed: true,
            version: None,
            status: "ready",
            message: None,
        }
    }
}

/// Run `<command> --version` and classify the outcome. The command string is
/// passed to the OS as-is (no shell splitting), matching how providers spawn
/// it elsewhere. A missing binary is the only outcome that counts as not
/// installed; a binary that exists but fails or hangs is installed but not
/// ready, same as t3code's probe.
pub async fn probe_command(command: &str) -> ProviderStatus {
    let run = Command::new(command)
        .arg("--version")
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(PROBE_TIMEOUT, run).await {
        Err(_) => ProviderStatus {
            installed: true,
            version: None,
            status: "error",
            message: Some(format!("timed out while checking `{command}`")),
        },
        Ok(Err(e)) if e.kind() == std::io::ErrorKind::NotFound => ProviderStatus {
            installed: false,
            version: None,
            status: "error",
            message: Some(format!("`{command}` was not found on PATH")),
        },
        Ok(Err(e)) => ProviderStatus {
            installed: true,
            version: None,
            status: "error",
            message: Some(format!("failed to run `{command}`: {e}")),
        },
        Ok(Ok(out)) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let version = crate::providers::version::parse_version_output(&stdout).or_else(|| {
                if stdout.is_empty() {
                    crate::providers::version::parse_version_output(&String::from_utf8_lossy(
                        &out.stderr,
                    ))
                } else {
                    None
                }
            });
            ProviderStatus {
                installed: true,
                version,
                status: "ready",
                message: None,
            }
        }
        Ok(Ok(out)) => ProviderStatus {
            installed: true,
            version: None,
            status: "error",
            message: Some(format!("`{command} --version` exited with {}", out.status)),
        },
    }
}

/// Probe results keyed by command, refreshed after [`STATUS_TTL`]. Shared via
/// [`crate::AppState`] so every request sees the same view of the host.
#[derive(Clone)]
pub struct ProviderStatusCache {
    cache: mini_moka::sync::Cache<String, ProviderStatus>,
    /// One lock per command so concurrent readers share a single probe
    /// instead of each spawning their own `<command> --version`.
    inflight: Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>,
}

impl ProviderStatusCache {
    pub fn new() -> Self {
        Self {
            cache: mini_moka::sync::Cache::builder()
                .max_capacity(64)
                .time_to_live(STATUS_TTL)
                .build(),
            inflight: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Drop the cached status for `command` so the next read re-probes it.
    /// Called when a command is saved or exercised by the health check.
    pub fn invalidate(&self, command: &str) {
        self.cache.invalidate(&command.to_string());
    }

    /// Return the cached status for `command`, probing it on a miss.
    pub async fn status_for(&self, command: &str) -> ProviderStatus {
        let command = command.trim();
        if command.is_empty() {
            return ProviderStatus::ready();
        }
        if let Some(status) = self.cache.get(&command.to_string()) {
            return status;
        }
        let lock = {
            let mut inflight = self.inflight.lock().await;
            inflight
                .entry(command.to_string())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        let _guard = lock.lock().await;
        // Another caller may have populated the cache while we waited.
        if let Some(status) = self.cache.get(&command.to_string()) {
            return status;
        }
        let status = probe_command(command).await;
        self.cache.insert(command.to_string(), status.clone());
        self.inflight.lock().await.remove(command);
        status
    }

    /// Probe the default command of every registered provider concurrently.
    /// Called once at backend start so the first `/api/providers` response is
    /// already accurate and the log records what this host can run.
    pub async fn probe_registered(&self) -> Vec<(String, ProviderStatus)> {
        let mut set = tokio::task::JoinSet::new();
        for p in super::available_providers() {
            let cache = self.clone();
            let command = super::default_command(p.id).to_string();
            set.spawn(async move { (p.id.to_string(), cache.status_for(&command).await) });
        }
        let mut out = set.join_all().await;
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }
}

impl Default for ProviderStatusCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_binary_is_not_installed() {
        let status = probe_command("definitely-not-a-real-binary-xyz").await;
        assert!(!status.installed);
        assert_eq!(status.status, "error");
        assert!(!status.is_ready());
        assert!(status.message.unwrap().contains("not found"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn working_binary_is_ready() {
        // `true` is universally present and exits 0 regardless of arguments.
        let status = probe_command("true").await;
        assert!(status.installed);
        assert_eq!(status.status, "ready");
        assert!(status.is_ready());
        assert!(status.message.is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failing_binary_is_installed_but_not_ready() {
        // `false` exists on PATH but exits non-zero regardless of arguments.
        let status = probe_command("false").await;
        assert!(status.installed);
        assert_eq!(status.status, "error");
        assert!(!status.is_ready());
    }

    #[tokio::test]
    async fn empty_command_counts_as_ready() {
        // The injected app-level provider has no command; assume it works.
        let status = ProviderStatusCache::new().status_for("").await;
        assert!(status.is_ready());
    }

    #[tokio::test]
    async fn cache_returns_same_result_within_ttl() {
        let cache = ProviderStatusCache::new();
        let first = cache.status_for("definitely-not-a-real-binary-xyz").await;
        let second = cache.status_for("definitely-not-a-real-binary-xyz").await;
        assert_eq!(first.installed, second.installed);
        assert_eq!(first.status, second.status);
        assert_eq!(first.message, second.message);
    }

    #[tokio::test]
    async fn concurrent_status_for_shares_one_probe() {
        let cache = ProviderStatusCache::new();
        let (a, b) = tokio::join!(
            cache.status_for("definitely-not-a-real-binary-xyz"),
            cache.status_for("definitely-not-a-real-binary-xyz"),
        );
        assert_eq!(a.installed, b.installed);
        assert_eq!(a.message, b.message);
        // The single-flight entry is removed once the probe completes.
        assert!(cache.inflight.lock().await.is_empty());
    }

    #[tokio::test]
    async fn probe_registered_covers_all_providers() {
        let cache = ProviderStatusCache::new();
        let results = cache.probe_registered().await;
        let mut ids: Vec<_> = results.iter().map(|(id, _)| id.as_str()).collect();
        ids.sort_unstable();
        assert_eq!(ids, ["codex", "devin-cli", "grok", "opencode"]);
        // Each entry must classify one way or the other; which way depends on
        // what the host running the test has installed.
        for (_, status) in &results {
            assert!(status.status == "ready" || status.status == "error");
        }
    }
}
