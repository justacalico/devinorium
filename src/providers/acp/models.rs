use once_cell::sync::Lazy;
use serde::Deserialize;
use tokio::process::Command;

use agent_client_protocol::{
    schema::v1::{ClientCapabilities, InitializeRequest},
    schema::ProtocolVersion as ProtocolVersionEnum,
    AcpAgent, Agent, Client, ConnectionTo,
};

use super::spec::AgentKind;
use crate::providers::ModelInfo;

/// Static model catalog used when the provider CLI cannot be queried.
pub fn static_models(kind: AgentKind) -> Vec<ModelInfo> {
    match kind {
        AgentKind::Devin => vec![
            ModelInfo {
                id: "glm-5-2".into(),
                label: "GLM-5.2 High".into(),
                cost_tier: "low".into(),
                family: "glm".into(),
                cost_summary: "Free".into(),
                max_context_tokens: 1_000_000,
                max_output_tokens: 128_000,
                is_new: false,
                is_beta: false,
                default_reasoning_effort: None,
                supported_reasoning_efforts: vec![],
            },
            ModelInfo {
                id: "claude-opus-5-medium".into(),
                label: "Claude Opus 5 Medium".into(),
                cost_tier: "high".into(),
                family: "claude".into(),
                cost_summary: "$5 / MTok In · $25 / MTok Out".into(),
                max_context_tokens: 1_000_000,
                max_output_tokens: 128_000,
                is_new: false,
                is_beta: false,
                default_reasoning_effort: None,
                supported_reasoning_efforts: vec![],
            },
        ],
        AgentKind::Opencode => vec![ModelInfo {
            id: "opencode/big-pickle".into(),
            label: "Big Pickle".into(),
            cost_tier: "free".into(),
            family: "opencode".into(),
            cost_summary: "Free".into(),
            max_context_tokens: 200_000,
            max_output_tokens: 32_000,
            is_new: false,
            is_beta: false,
            default_reasoning_effort: None,
            supported_reasoning_efforts: vec![],
        }],
        AgentKind::Grok => vec![ModelInfo {
            id: "grok-4.6".into(),
            label: "Grok 4.6".into(),
            cost_tier: String::new(),
            family: "xai".into(),
            cost_summary: String::new(),
            max_context_tokens: 500_000,
            max_output_tokens: 0,
            is_new: false,
            is_beta: false,
            default_reasoning_effort: Some("high".into()),
            supported_reasoning_efforts: vec![
                "low".into(),
                "medium".into(),
                "high".into(),
                "xhigh".into(),
            ],
        }],
    }
}

pub static DEVIN_MODELS: Lazy<Vec<ModelInfo>> = Lazy::new(|| static_models(AgentKind::Devin));

/// List the models `opencode` knows about. `opencode models --verbose`
/// prints alternating model slugs and pretty-printed JSON metadata blocks:
///
/// ```text
/// opencode/big-pickle
/// {
///   "id": "big-pickle",
///   "providerID": "opencode",
///   "name": "Big Pickle",
///   ...
/// }
/// ```
///
/// Falls back to the plain `opencode models` slug list when the verbose
/// output cannot be parsed.
pub async fn fetch_opencode_models(bin: &str) -> anyhow::Result<Vec<ModelInfo>> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        Command::new(bin)
            .args(["models", "--verbose"])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("opencode models timed out"))??;

    if !output.status.success() {
        anyhow::bail!(
            "opencode models failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let models = parse_opencode_models_verbose(&stdout);
    if !models.is_empty() {
        return Ok(models);
    }

    let plain = parse_opencode_models_plain(&stdout);
    if !plain.is_empty() {
        return Ok(plain);
    }

    // The verbose flag may be unsupported on older builds; try the plain list.
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        Command::new(bin).arg("models").kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("opencode models timed out"))??;
    if !output.status.success() {
        anyhow::bail!(
            "opencode models failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(parse_opencode_models_plain(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

/// List the models `grok` can serve. `grok models` only prints ids, so this
/// opens the ACP connection, runs `initialize`, and reads
/// `_meta.modelState.availableModels` from the response — no session is
/// created and no prompt runs.
pub async fn fetch_grok_models(bin: &str) -> anyhow::Result<Vec<ModelInfo>> {
    let argv: Vec<String> = std::iter::once(bin.to_string())
        .chain(AgentKind::Grok.acp_args().iter().map(|s| s.to_string()))
        .collect();
    let handshake = Client.builder().name("devinorium").connect_with(
        AcpAgent::from_args(argv)?,
        async move |connection: ConnectionTo<Agent>| {
            connection
                .send_request(
                    InitializeRequest::new(ProtocolVersionEnum::V1)
                        .client_capabilities(ClientCapabilities::new()),
                )
                .block_task()
                .await
        },
    );
    let response = tokio::time::timeout(std::time::Duration::from_secs(15), handshake)
        .await
        .map_err(|_| anyhow::anyhow!("grok model list timed out"))??;
    Ok(parse_grok_models(response.meta.as_ref()))
}

#[derive(Deserialize)]
struct GrokModelMeta {
    #[serde(default, rename = "totalContextTokens")]
    total_context_tokens: u64,
    #[serde(default, rename = "reasoningEffort")]
    reasoning_effort: Option<String>,
    #[serde(default, rename = "reasoningEfforts")]
    reasoning_efforts: Vec<GrokReasoningEffort>,
}

#[derive(Deserialize)]
struct GrokReasoningEffort {
    #[serde(default)]
    value: String,
    #[serde(default)]
    default: bool,
}

#[derive(Deserialize)]
struct GrokAvailableModel {
    #[serde(default, rename = "modelId")]
    model_id: String,
    #[serde(default)]
    name: String,
    #[serde(default, rename = "_meta")]
    meta: Option<GrokModelMeta>,
}

/// Parse the `modelState.availableModels` list from an initialize response
/// `_meta` blob into the shared model catalog shape.
pub fn parse_grok_models(
    meta: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Vec<ModelInfo> {
    let Some(models) = meta
        .and_then(|m| m.get("modelState"))
        .and_then(|s| s.get("availableModels"))
        .and_then(|a| a.as_array())
    else {
        return Vec::new();
    };

    models
        .iter()
        .filter_map(|m| serde_json::from_value::<GrokAvailableModel>(m.clone()).ok())
        .filter(|m| !m.model_id.is_empty())
        .map(|m| {
            let meta = m.meta.unwrap_or(GrokModelMeta {
                total_context_tokens: 0,
                reasoning_effort: None,
                reasoning_efforts: Vec::new(),
            });
            let supported: Vec<String> = meta
                .reasoning_efforts
                .iter()
                .map(|e| e.value.clone())
                .filter(|v| !v.is_empty())
                .collect();
            let default_effort = meta
                .reasoning_efforts
                .iter()
                .find(|e| e.default)
                .map(|e| e.value.clone())
                .or(meta.reasoning_effort)
                .filter(|v| supported.iter().any(|s| s == v));
            ModelInfo {
                id: m.model_id.clone(),
                label: if m.name.is_empty() {
                    m.model_id
                } else {
                    m.name
                },
                cost_tier: String::new(),
                family: "xai".into(),
                cost_summary: String::new(),
                max_context_tokens: meta.total_context_tokens,
                max_output_tokens: 0,
                is_new: false,
                is_beta: false,
                default_reasoning_effort: default_effort,
                supported_reasoning_efforts: supported,
            }
        })
        .collect()
}

#[derive(Deserialize)]
struct OpencodeModelMeta {
    #[serde(default)]
    name: String,
    #[serde(default, rename = "providerID")]
    provider_id: String,
    #[serde(default)]
    family: String,
    #[serde(default)]
    cost: OpencodeCost,
    #[serde(default)]
    limit: OpencodeLimit,
}

#[derive(Deserialize, Default)]
struct OpencodeCost {
    #[serde(default)]
    input: f64,
    #[serde(default)]
    output: f64,
}

#[derive(Deserialize, Default)]
struct OpencodeLimit {
    #[serde(default)]
    context: u64,
    #[serde(default)]
    output: u64,
}

/// Parse `opencode models --verbose` output: a bare slug line followed by a
/// pretty-printed JSON object, repeated per model.
pub fn parse_opencode_models_verbose(out: &str) -> Vec<ModelInfo> {
    let mut models = Vec::new();
    let mut slug: Option<&str> = None;
    let mut json = String::new();
    let mut depth = 0i32;

    for line in out.lines() {
        if depth == 0 && !line.trim_start().starts_with('{') {
            // A non-JSON line names the model whose metadata follows.
            if !line.trim().is_empty() {
                slug = Some(line.trim());
            }
            continue;
        }
        json.push_str(line);
        json.push('\n');
        depth += line.matches('{').count() as i32;
        depth -= line.matches('}').count() as i32;
        if depth <= 0 {
            if let (Some(slug), Ok(meta)) = (
                slug.take(),
                serde_json::from_str::<OpencodeModelMeta>(&json),
            ) {
                models.push(opencode_model_info(slug, meta));
            }
            json.clear();
            depth = 0;
        }
    }
    models
}

/// Parse plain `opencode models` output: one `provider/model` slug per line.
pub fn parse_opencode_models_plain(out: &str) -> Vec<ModelInfo> {
    out.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && l.contains('/') && !l.contains(char::is_whitespace))
        .map(|slug| ModelInfo {
            id: slug.to_string(),
            label: slug
                .split_once('/')
                .map(|(_, m)| m.to_string())
                .unwrap_or_else(|| slug.to_string()),
            cost_tier: String::new(),
            family: slug
                .split_once('/')
                .map(|(p, _)| p.to_string())
                .unwrap_or_default(),
            cost_summary: String::new(),
            max_context_tokens: 0,
            max_output_tokens: 0,
            is_new: false,
            is_beta: false,
            default_reasoning_effort: None,
            supported_reasoning_efforts: vec![],
        })
        .collect()
}

fn opencode_model_info(slug: &str, meta: OpencodeModelMeta) -> ModelInfo {
    let free = meta.cost.input == 0.0 && meta.cost.output == 0.0;
    ModelInfo {
        id: slug.to_string(),
        label: if meta.name.is_empty() {
            slug.to_string()
        } else {
            meta.name
        },
        cost_tier: if free { "free" } else { "paid" }.to_string(),
        family: if meta.family.is_empty() {
            meta.provider_id
        } else {
            meta.family
        },
        cost_summary: if free {
            "Free".to_string()
        } else {
            format!(
                "${} / MTok In · ${} / MTok Out",
                meta.cost.input, meta.cost.output
            )
        },
        max_context_tokens: meta.limit.context,
        max_output_tokens: meta.limit.output,
        is_new: false,
        is_beta: false,
        default_reasoning_effort: None,
        supported_reasoning_efforts: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_models_includes_known_entries() {
        let models = static_models(AgentKind::Devin);
        assert_eq!(models.len(), 2);
        assert!(models.iter().any(|m| m.id == "glm-5-2"));
        assert!(models.iter().any(|m| m.id == "claude-opus-5-medium"));
    }

    #[test]
    fn models_lazy_static_matches_static_models() {
        assert_eq!(DEVIN_MODELS.len(), static_models(AgentKind::Devin).len());
        assert_eq!(DEVIN_MODELS[0].id, "glm-5-2");
    }

    #[test]
    fn static_models_opencode_has_free_zen_model() {
        let models = static_models(AgentKind::Opencode);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "opencode/big-pickle");
        assert_eq!(models[0].cost_tier, "free");
    }

    #[test]
    fn static_models_grok_lists_reasoning_efforts() {
        let models = static_models(AgentKind::Grok);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "grok-4.6");
        assert_eq!(models[0].default_reasoning_effort.as_deref(), Some("high"));
        assert!(models[0]
            .supported_reasoning_efforts
            .contains(&"low".to_string()));
    }

    #[test]
    fn parse_grok_models_reads_initialize_meta() {
        let meta = serde_json::json!({
            "modelState": {
                "currentModelId": "grok-4.6",
                "availableModels": [{
                    "modelId": "grok-4.6",
                    "name": "Grok 4.6",
                    "description": "SpaceXAI's latest frontier model",
                    "_meta": {
                        "totalContextTokens": 500000,
                        "supportsReasoningEffort": true,
                        "reasoningEffort": "high",
                        "reasoningEfforts": [
                            {"id": "xhigh", "value": "xhigh", "label": "Extra High Effort", "default": false},
                            {"id": "high", "value": "high", "label": "High Effort", "default": true},
                            {"id": "medium", "value": "medium", "label": "Medium Effort", "default": false},
                            {"id": "low", "value": "low", "label": "Low Effort", "default": false}
                        ]
                    }
                }]
            }
        })
        .as_object()
        .unwrap()
        .clone();

        let models = parse_grok_models(Some(&meta));
        assert_eq!(models.len(), 1);
        let m = &models[0];
        assert_eq!(m.id, "grok-4.6");
        assert_eq!(m.label, "Grok 4.6");
        assert_eq!(m.max_context_tokens, 500_000);
        assert_eq!(m.default_reasoning_effort.as_deref(), Some("high"));
        assert_eq!(
            m.supported_reasoning_efforts,
            vec!["xhigh", "high", "medium", "low"]
        );
    }

    #[test]
    fn parse_grok_models_handles_missing_meta() {
        assert!(parse_grok_models(None).is_empty());
        let meta = serde_json::Map::new();
        assert!(parse_grok_models(Some(&meta)).is_empty());
    }

    #[test]
    fn parse_grok_models_falls_back_to_id_and_declared_effort() {
        let meta = serde_json::json!({
            "modelState": {
                "availableModels": [{
                    "modelId": "grok-x",
                    "_meta": {"reasoningEffort": "medium"}
                }]
            }
        })
        .as_object()
        .unwrap()
        .clone();

        let models = parse_grok_models(Some(&meta));
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].label, "grok-x");
        // A declared effort that is not in the advertised list is dropped.
        assert_eq!(models[0].default_reasoning_effort, None);
        assert!(models[0].supported_reasoning_efforts.is_empty());
    }

    #[test]
    fn parse_verbose_models_reads_slug_and_metadata() {
        let out = "opencode/big-pickle\n{\n  \"id\": \"big-pickle\",\n  \"providerID\": \"opencode\",\n  \"name\": \"Big Pickle\",\n  \"family\": \"big-pickle\",\n  \"cost\": { \"input\": 0, \"output\": 0 },\n  \"limit\": { \"context\": 200000, \"output\": 32000 }\n}\nopenai/gpt-5\n{\n  \"id\": \"gpt-5\",\n  \"providerID\": \"openai\",\n  \"name\": \"GPT-5\",\n  \"cost\": { \"input\": 1.25, \"output\": 10 },\n  \"limit\": { \"context\": 400000, \"output\": 128000 }\n}\n";
        let models = parse_opencode_models_verbose(out);
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "opencode/big-pickle");
        assert_eq!(models[0].label, "Big Pickle");
        assert_eq!(models[0].cost_tier, "free");
        assert_eq!(models[0].cost_summary, "Free");
        assert_eq!(models[0].max_context_tokens, 200_000);
        assert_eq!(models[0].max_output_tokens, 32_000);
        assert_eq!(models[1].id, "openai/gpt-5");
        assert_eq!(models[1].family, "openai");
        assert_eq!(models[1].cost_tier, "paid");
        assert!(models[1].cost_summary.contains("1.25"));
    }

    #[test]
    fn parse_verbose_models_skips_unparseable_blocks() {
        let out = "opencode/good\n{\n  \"name\": \"Good\"\n}\nopencode/bad\n{ not json }\n";
        let models = parse_opencode_models_verbose(out);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "opencode/good");
    }

    #[test]
    fn parse_plain_models_reads_slugs() {
        let out = "opencode/big-pickle\nopenai/gpt-5\n\n  \nnot a slug line with spaces\n";
        let models = parse_opencode_models_plain(out);
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "opencode/big-pickle");
        assert_eq!(models[0].family, "opencode");
        assert_eq!(models[0].label, "big-pickle");
        assert_eq!(models[1].id, "openai/gpt-5");
    }

    #[test]
    fn parse_verbose_models_empty_input() {
        assert!(parse_opencode_models_verbose("").is_empty());
        assert!(parse_opencode_models_verbose("no models here").is_empty());
    }
}
