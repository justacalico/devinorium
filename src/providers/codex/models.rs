//! Model catalog for the Codex provider: live `model/list` against the
//! app-server plus a minimal fallback for when the binary cannot run.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde_json::json;

use crate::providers::ModelInfo;

use super::rpc::AppServer;
use super::wire::ModelListResponse;

/// Open a server, run `model/list`, and map the catalog onto [`ModelInfo`].
/// Hidden models are skipped. The whole exchange is bounded by
/// [`MODEL_FETCH_TIMEOUT`] so a wedged binary cannot stall a prompt.
pub async fn fetch_models(bin: &str, cwd: &Path) -> anyhow::Result<Vec<ModelInfo>> {
    fetch_models_timed(bin, cwd, MODEL_FETCH_TIMEOUT).await
}

async fn fetch_models_timed(
    bin: &str,
    cwd: &Path,
    dur: Duration,
) -> anyhow::Result<Vec<ModelInfo>> {
    match tokio::time::timeout(dur, fetch_catalog(bin, cwd)).await {
        Ok(result) => result,
        Err(_) => anyhow::bail!("model/list timed out after {}s", dur.as_secs()),
    }
}

async fn fetch_catalog(bin: &str, cwd: &Path) -> anyhow::Result<Vec<ModelInfo>> {
    let server = AppServer::spawn(bin, cwd).await?;
    super::provider::handshake(&server).await?;

    let result = server
        .request("model/list", json!({ "limit": 64, "includeHidden": false }))
        .await?;
    let list: ModelListResponse = serde_json::from_value(result)?;

    Ok(list
        .data
        .into_iter()
        .filter(|m| !m.hidden)
        .map(|m| {
            let id = if m.model.is_empty() { m.id } else { m.model };
            ModelInfo {
                label: if m.display_name.is_empty() {
                    id.clone()
                } else {
                    m.display_name
                },
                id,
                cost_tier: String::new(),
                family: "codex".into(),
                cost_summary: m.description,
                max_context_tokens: 0,
                max_output_tokens: 0,
                is_new: false,
                is_beta: false,
                default_reasoning_effort: m.default_reasoning_effort.filter(|s| !s.is_empty()),
                supported_reasoning_efforts: m
                    .supported_reasoning_efforts
                    .into_iter()
                    .map(|e| e.reasoning_effort)
                    .filter(|e| !e.is_empty())
                    .collect(),
            }
        })
        .collect())
}

/// Fallback used when `codex` is missing or `model/list` fails. The empty id
/// means "use whatever the CLI is configured with" — `run_prompt` omits the
/// `model` field for it.
pub fn static_models() -> Vec<ModelInfo> {
    vec![ModelInfo {
        id: String::new(),
        label: "Codex default".into(),
        cost_tier: String::new(),
        family: "codex".into(),
        cost_summary: "Whatever `~/.codex/config.toml` configures".into(),
        max_context_tokens: 0,
        max_output_tokens: 0,
        is_new: false,
        is_beta: false,
        default_reasoning_effort: None,
        supported_reasoning_efforts: vec![],
    }]
}

/// How long a successful `model/list` result stays cached.
const MODEL_CACHE_TTL: Duration = Duration::from_secs(300);
/// Failed lookups get a much shorter TTL so a fixed binary is picked up
/// quickly instead of staying dead until restart.
const MODEL_CACHE_FAIL_TTL: Duration = Duration::from_secs(30);
/// Bound on spawn + handshake + `model/list` for one catalog fetch.
const MODEL_FETCH_TIMEOUT: Duration = Duration::from_secs(15);

struct CacheEntry {
    at: Instant,
    models: Option<Vec<ModelInfo>>,
}

/// Process-wide `model/list` cache keyed by binary path. Providers are
/// rebuilt per request, so an instance field would respawn a server (and a
/// second codex process) on every prompt.
static MODEL_CACHE: Lazy<Mutex<HashMap<String, CacheEntry>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// The model catalog the binary advertises, or `None` when the lookup
/// failed. Cached per binary with a TTL: successes last [`MODEL_CACHE_TTL`],
/// failures only [`MODEL_CACHE_FAIL_TTL`].
pub async fn known_models(bin: &str, cwd: &Path) -> Option<Vec<ModelInfo>> {
    {
        let cache = MODEL_CACHE.lock().unwrap();
        if let Some(entry) = cache.get(bin) {
            let ttl = if entry.models.is_some() {
                MODEL_CACHE_TTL
            } else {
                MODEL_CACHE_FAIL_TTL
            };
            if entry.at.elapsed() < ttl {
                return entry.models.clone();
            }
        }
    }
    let fetched = fetch_models(bin, cwd).await.ok();
    MODEL_CACHE.lock().unwrap().insert(
        bin.to_string(),
        CacheEntry {
            at: Instant::now(),
            models: fetched.clone(),
        },
    );
    fetched
}

/// Model ids the binary advertises, or `None` when the lookup failed.
pub async fn known_model_ids(bin: &str, cwd: &Path) -> Option<HashSet<String>> {
    known_models(bin, cwd).await.map(|ms| {
        ms.into_iter()
            .map(|m| m.id)
            .filter(|id| !id.is_empty())
            .collect()
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Minimal fake codex app-server: answers `initialize` and `model/list`,
    /// recording each `model/list` hit so tests can count refetches.
    fn fake_codex(dir: &Path) -> PathBuf {
        let path = dir.join("codex");
        let script = r#"#!/bin/sh
id_of() { printf '%s' "$1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id"
      ;;
    *'"method":"model/list"'*)
      echo hit >> "__DIR__/hits"
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"data":[{"id":"m1","model":"m1","displayName":"M1","description":"d","hidden":false,"isDefault":true,"defaultReasoningEffort":"","supportedReasoningEfforts":[]}]}}\n' "$id"
      ;;
  esac
done
"#
        .replace("__DIR__", &dir.display().to_string());
        std::fs::write(&path, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// Fake that answers `initialize` then goes silent so `model/list`
    /// hangs until the outer timeout fires.
    fn hanging_codex(dir: &Path) -> PathBuf {
        let path = dir.join("codex");
        let script = r#"#!/bin/sh
id_of() { printf '%s' "$1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id"
      ;;
  esac
done
"#;
        std::fs::write(&path, script).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn seed(bin: &str, age: Duration, models: Option<Vec<ModelInfo>>) {
        MODEL_CACHE.lock().unwrap().insert(
            bin.to_string(),
            CacheEntry {
                at: Instant::now() - age,
                models,
            },
        );
    }

    fn hits(dir: &Path) -> usize {
        std::fs::read_to_string(dir.join("hits"))
            .map(|s| s.lines().count())
            .unwrap_or(0)
    }

    #[tokio::test]
    async fn fresh_cache_hit_skips_spawn() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("missing-codex"); // would fail if spawned
        seed(
            bin.to_str().unwrap(),
            Duration::ZERO,
            Some(static_models()),
        );
        let got = known_models(bin.to_str().unwrap(), dir.path()).await;
        assert!(got.is_some());
    }

    #[tokio::test]
    async fn expired_failure_refetches() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let key = bin.to_str().unwrap().to_string();
        seed(&key, MODEL_CACHE_FAIL_TTL + Duration::from_secs(1), None);

        let got = known_models(&key, dir.path()).await;
        assert!(got.is_some());
        assert_eq!(hits(dir.path()), 1);
    }

    #[tokio::test]
    async fn fresh_failure_stays_cached() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let key = bin.to_str().unwrap().to_string();
        seed(&key, Duration::ZERO, None);

        let got = known_models(&key, dir.path()).await;
        assert!(got.is_none());
        assert_eq!(hits(dir.path()), 0);
    }

    #[tokio::test]
    async fn expired_success_refetches() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let key = bin.to_str().unwrap().to_string();
        seed(&key, MODEL_CACHE_TTL + Duration::from_secs(1), Some(static_models()));

        let got = known_models(&key, dir.path()).await.unwrap();
        assert_eq!(got[0].id, "m1");
        assert_eq!(hits(dir.path()), 1);
    }

    #[tokio::test]
    async fn fetch_models_times_out_on_silent_agent() {
        let dir = tempfile::tempdir().unwrap();
        let bin = hanging_codex(dir.path());
        let err = fetch_models_timed(
            bin.to_str().unwrap(),
            dir.path(),
            Duration::from_millis(300),
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("timed out"));
    }
}
