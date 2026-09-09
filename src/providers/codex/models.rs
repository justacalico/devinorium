//! Model catalog for the Codex provider: live `model/list` against the
//! app-server plus a minimal fallback for when the binary cannot run.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;

use once_cell::sync::Lazy;
use serde_json::json;

use crate::providers::ModelInfo;

use super::rpc::AppServer;
use super::wire::ModelListResponse;

/// Open a server, run `model/list`, and map the catalog onto [`ModelInfo`].
/// Hidden models are skipped.
pub async fn fetch_models(bin: &str, cwd: &Path) -> anyhow::Result<Vec<ModelInfo>> {
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

/// Process-wide `model/list` cache keyed by binary path. Providers are
/// rebuilt per request, so an instance field would respawn a server (and a
/// second codex process) on every prompt.
static MODEL_CACHE: Lazy<Mutex<HashMap<String, Option<Vec<ModelInfo>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// The model catalog the binary advertises, or `None` when the lookup
/// failed. Cached after the first successful or failed fetch per binary.
pub async fn known_models(bin: &str, cwd: &Path) -> Option<Vec<ModelInfo>> {
    if let Some(cached) = MODEL_CACHE.lock().unwrap().get(bin) {
        return cached.clone();
    }
    let fetched = fetch_models(bin, cwd).await.ok();
    MODEL_CACHE
        .lock()
        .unwrap()
        .insert(bin.to_string(), fetched.clone());
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
