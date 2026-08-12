//! Devin CLI ACP (Agent Client Protocol) provider.
//!
//! Spawns `devin acp` and communicates over JSON-RPC stdio using the
//! `agent-client-protocol` crate. Permission requests can be forwarded to the
//! API layer through the optional [`SendOptions::permission_callback`]; if no
//! callback is configured, permission requests are rejected.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;

use super::{
    title_from_prompt, Attachment, ModelInfo, PermissionCallback, PermissionOption,
    PermissionOutcome, PermissionRequest, Provider, SendOptions, SendRequest, SendResponse,
    StartRequest, StartResponse, StreamChunkCallback,
};
use agent_client_protocol::{
    schema::v1::{
        ContentBlock, EmbeddedResourceResource, InitializeRequest, LoadSessionRequest,
        LoadSessionResponse, NewSessionRequest, NewSessionResponse,
        PermissionOption as AcpPermissionOption, PromptRequest, RequestPermissionOutcome,
        RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
        SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionValue,
        SessionConfigSelectOptions, SessionId, SessionNotification, SetSessionConfigOptionRequest,
        TextContent, ToolCallContent,
    },
    schema::ProtocolVersion,
    AcpAgent, Agent, Client, ConnectionTo,
};

const PROVIDER_ID: &str = "devin-cli";
const PROVIDER_NAME: &str = "Devin CLI";

pub struct DevinAcpProvider {
    bin: String,
    default_model: String,
}

impl DevinAcpProvider {
    pub fn new(bin: String, default_model: String) -> Self {
        Self { bin, default_model }
    }

    async fn run_prompt(
        &self,
        options: &SendOptions,
        maybe_session: Option<&str>,
        prompt: String,
    ) -> anyhow::Result<(String, String, String)> {
        let prompt = self
            .with_attachments(prompt, &options.attachments, &options.working_dir)
            .await?;

        let text_acc = Arc::new(Mutex::new(String::new()));
        let thinking_acc = Arc::new(Mutex::new(String::new()));
        let text_callback = options.text_callback.clone();
        let thinking_callback = options.thinking_callback.clone();

        let cwd = options.working_dir.clone();
        let maybe_session = maybe_session.map(|s| s.to_string());
        let permission_callback = options.permission_callback.clone();

        let result = Client
            .builder()
            .name("devinorium")
            .on_receive_notification(
                {
                    let text_acc = text_acc.clone();
                    let thinking_acc = thinking_acc.clone();
                    let text_callback = text_callback.clone();
                    let thinking_callback = thinking_callback.clone();
                    async move |notification: SessionNotification, _cx| {
                        let (text, thinking) = extract_text_from_notification(&notification).await;
                        if let Some(t) = text {
                            emit_chunk(&text_acc, text_callback.as_ref(), t).await;
                        }
                        if let Some(t) = thinking {
                            emit_chunk(&thinking_acc, thinking_callback.as_ref(), t).await;
                        }
                        Ok(())
                    }
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                {
                    let permission_callback = permission_callback.clone();
                    async move |request: RequestPermissionRequest, responder, _cx| {
                        let outcome =
                            handle_permission_request(request, permission_callback.as_ref()).await;
                        responder.respond(RequestPermissionResponse::new(outcome))
                    }
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_with(
                AcpAgent::from_args([&self.bin, "acp"])?,
                async move |connection: ConnectionTo<Agent>| {
                    let _init_response = connection
                        .send_request(InitializeRequest::new(ProtocolVersion::V1))
                        .block_task()
                        .await?;

                    let (session_id, config_options) = if let Some(ref sid) = maybe_session {
                        let load_resp: LoadSessionResponse = connection
                            .send_request(LoadSessionRequest::new(
                                agent_client_protocol::schema::v1::SessionId::new(sid.clone()),
                                cwd.clone(),
                            ))
                            .block_task()
                            .await?;
                        (sid.clone(), load_resp.config_options)
                    } else {
                        let resp: NewSessionResponse = connection
                            .send_request(NewSessionRequest::new(cwd.clone()))
                            .block_task()
                            .await?;
                        (resp.session_id.to_string(), resp.config_options)
                    };

                    apply_session_config(
                        &connection,
                        &session_id,
                        &self.default_model,
                        options,
                        config_options.as_deref(),
                    )
                    .await?;

                    let prompt_blocks = vec![ContentBlock::Text(TextContent::new(prompt))];

                    let _prompt_response = connection
                        .send_request(PromptRequest::new(session_id.clone(), prompt_blocks))
                        .block_task()
                        .await?;

                    // After the prompt completes, gather any text/thinking that arrived.
                    let reply = text_acc.lock().await.clone();
                    let thinking = thinking_acc.lock().await.clone();

                    Ok::<_, agent_client_protocol::Error>((session_id, reply, thinking))
                },
            )
            .await
            .map_err(|e| anyhow::anyhow!("acp connection failed: {e}"));

        result
    }

    async fn with_attachments(
        &self,
        prompt: String,
        attachments: &[Attachment],
        working_dir: &Path,
    ) -> anyhow::Result<String> {
        if attachments.is_empty() {
            return Ok(prompt);
        }

        let att_dir = working_dir.join(".devinorium-attachments");
        tokio::fs::create_dir_all(&att_dir).await?;

        let mut parts = vec![prompt];
        for (i, att) in attachments.iter().enumerate() {
            let name = format!("{}_{}", i, sanitize(&att.filename));
            let path = att_dir.join(&name);
            tokio::fs::write(&path, &att.data).await?;
            parts.push(format!(
                "\n\n[Attachment {}: {} ({} bytes)]\n@{}
",
                i,
                att.filename,
                att.data.len(),
                path.display()
            ));
        }

        Ok(parts.join(""))
    }

    /// Run `devin models list --format json` and parse the same JSON shape as
    /// the legacy CLI provider. Returns an empty vector if devin is not
    /// available or returns an unexpected shape.
    async fn fetch_devin_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        let output = Command::new(&self.bin)
            .args(["models", "list", "--format", "json"])
            .current_dir(".")
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "devin models list failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        #[derive(Deserialize)]
        struct Family {
            family_label: String,
            #[serde(default)]
            #[allow(dead_code)]
            family_uid: String,
            variants: Vec<Variant>,
        }

        #[derive(Deserialize)]
        struct Variant {
            model_uid: String,
            label: String,
            #[serde(default)]
            cost_tier: String,
        }

        #[derive(Deserialize)]
        struct Doc {
            families: Vec<Family>,
        }

        let doc: Doc = serde_json::from_slice(&output.stdout)?;
        let mut models = Vec::new();
        for f in doc.families {
            for v in f.variants {
                models.push(ModelInfo {
                    id: v.model_uid,
                    label: v.label,
                    cost_tier: v.cost_tier,
                    family: f.family_label.clone(),
                });
            }
        }

        Ok(models)
    }
}

async fn apply_session_config(
    connection: &ConnectionTo<Agent>,
    session_id: &str,
    default_model: &str,
    options: &SendOptions,
    config_options: Option<&[SessionConfigOption]>,
) -> anyhow::Result<()> {
    let config_options = match config_options {
        Some(c) => c,
        None => return Ok(()),
    };

    let session_id = SessionId::new(session_id.to_string());

    if let Some(model_opt) = config_options.iter().find(|o| o.id.0.as_ref() == "model") {
        let choices = select_values(model_opt);
        let requested = options.model.trim();
        let model = if !requested.is_empty() && choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if !default_model.is_empty() && choices.iter().any(|v| v == default_model) {
            default_model.to_string()
        } else if let Some(first) = choices.first() {
            first.clone()
        } else {
            return Ok(());
        };

        if !requested.is_empty() && requested != model {
            tracing::warn!(
                session_id = %session_id,
                requested = %requested,
                model = %model,
                "requested model not in ACP choices, using fallback"
            );
        }

        tracing::info!(session_id = %session_id, model = %model, "setting devin acp model");
        if let Err(e) = connection
            .send_request(SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new("model"),
                SessionConfigOptionValue::value_id(model),
            ))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp model");
        }
    }

    if let Some(mode_opt) = config_options.iter().find(|o| o.id.0.as_ref() == "mode") {
        let choices = select_values(mode_opt);
        let requested = options.permission_mode.trim();

        let mode = if choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if requested == "bypass" || requested == "yolo" {
            // The Devin CLI historically uses `dangerous`; ACP agents may
            // expose it as `autonomous`.
            if let Some(v) = choices
                .iter()
                .find(|v| *v == "dangerous" || *v == "autonomous")
            {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    mode = %v,
                    "mapping permission mode alias to ACP mode"
                );
                v.clone()
            } else {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    "ACP agent has no auto-run mode, falling back"
                );
                if let Some(first) = choices.first() {
                    first.clone()
                } else {
                    return Ok(());
                }
            }
        } else if ["normal", "accept-edits", "smart", "ask", "plan"].contains(&requested) {
            if let Some(fallback) = choices
                .iter()
                .find(|v| *v == "normal")
                .or_else(|| choices.first())
            {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    fallback = %fallback,
                    "permission mode not in ACP choices, falling back"
                );
                fallback.clone()
            } else {
                return Ok(());
            }
        } else if let Some(first) = choices.first() {
            tracing::warn!(
                session_id = %session_id,
                requested = %requested,
                first = %first,
                "unknown permission mode, falling back to first available"
            );
            first.clone()
        } else {
            return Ok(());
        };

        tracing::info!(session_id = %session_id, mode = %mode, "setting devin acp mode");
        if let Err(e) = connection
            .send_request(SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new("mode"),
                SessionConfigOptionValue::value_id(mode),
            ))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp mode");
        }
    }

    Ok(())
}

fn select_values(opt: &SessionConfigOption) -> Vec<String> {
    match &opt.kind {
        SessionConfigKind::Select(select) => match &select.options {
            SessionConfigSelectOptions::Ungrouped(opts) => {
                opts.iter().map(|o| o.value.0.to_string()).collect()
            }
            SessionConfigSelectOptions::Grouped(groups) => groups
                .iter()
                .flat_map(|g| g.options.iter().map(|o| o.value.0.to_string()))
                .collect(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

async fn handle_permission_request(
    request: RequestPermissionRequest,
    permission_callback: Option<&PermissionCallback>,
) -> RequestPermissionOutcome {
    if let Some(callback) = permission_callback {
        let permission_request = map_permission_request(&request);
        tracing::info!(scope = %permission_request.scope, "forwarding acp permission request");
        match callback(permission_request).await {
            PermissionOutcome::Allow { option_id } => {
                tracing::info!(option_id = %option_id, "permission request allowed");
                RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(option_id))
            }
            PermissionOutcome::Cancel => RequestPermissionOutcome::Cancelled,
        }
    } else {
        // No interactive handler (e.g. the non-stream /send endpoint). We
        // cannot safely get user consent, so reject the request instead of
        // auto-approving.
        tracing::warn!("no permission callback configured; rejecting ACP permission request");
        RequestPermissionOutcome::Cancelled
    }
}

fn map_permission_request(request: &RequestPermissionRequest) -> PermissionRequest {
    let request_id = uuid::Uuid::new_v4().to_string();
    let scope = format!("{}", request.tool_call.tool_call_id);
    let title = request
        .tool_call
        .fields
        .title
        .clone()
        .or_else(|| {
            request
                .tool_call
                .fields
                .kind
                .as_ref()
                .map(|k| format!("{k:?}"))
        })
        .unwrap_or_else(|| "Run command".to_string());
    let input = request
        .tool_call
        .fields
        .raw_input
        .as_ref()
        .map(|v| serde_json::to_string_pretty(v).unwrap_or_else(|_| v.to_string()));
    let options = request.options.iter().map(map_permission_option).collect();
    PermissionRequest {
        request_id,
        scope,
        title,
        input,
        options,
    }
}

fn map_permission_option(option: &AcpPermissionOption) -> PermissionOption {
    let label = Some(option.name.clone());
    PermissionOption {
        id: option.option_id.to_string(),
        kind: format!("{:?}", option.kind),
        label,
    }
}

async fn extract_text_from_notification(
    notification: &SessionNotification,
) -> (Option<String>, Option<String>) {
    use agent_client_protocol::schema::v1::SessionUpdate;
    match &notification.update {
        SessionUpdate::AgentMessageChunk(chunk) => {
            (text_from_content_block(&chunk.content), None)
        }
        SessionUpdate::AgentThoughtChunk(chunk) => {
            (None, text_from_content_block(&chunk.content))
        }
        SessionUpdate::ToolCall(tool_call) => {
            let text = tool_call
                .content
                .iter()
                .filter_map(|c| match c {
                    ToolCallContent::Content(content) => text_from_content_block(&content.content),
                    _ => None,
                })
                .next();
            (text, None)
        }
        SessionUpdate::ToolCallUpdate(update) => {
            let text = update.fields.content.as_ref().and_then(|contents| {
                contents
                    .iter()
                    .filter_map(|c| match c {
                        ToolCallContent::Content(content) => {
                            text_from_content_block(&content.content)
                        }
                        _ => None,
                    })
                    .next()
            });
            (text, None)
        }
        _ => (None, None),
    }
}

async fn emit_chunk(
    acc: &Mutex<String>,
    callback: Option<&StreamChunkCallback>,
    chunk: String,
) {
    let mut guard = acc.lock().await;
    guard.push_str(&chunk);
    if let Some(cb) = callback {
        cb(chunk);
    }
}

fn text_from_content_block(block: &ContentBlock) -> Option<String> {
    match block {
        ContentBlock::Text(t) => Some(t.text.clone()),
        ContentBlock::Resource(r) => match &r.resource {
            EmbeddedResourceResource::TextResourceContents(t) => Some(t.text.clone()),
            _ => None,
        },
        _ => None,
    }
}

fn sanitize(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn static_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "glm-5-2".into(),
            label: "GLM-5.2 High".into(),
            cost_tier: "low".into(),
            family: "glm".into(),
        },
        ModelInfo {
            id: "claude-opus-5-medium".into(),
            label: "Claude Opus 5 Medium".into(),
            cost_tier: "high".into(),
            family: "claude".into(),
        },
    ]
}

#[async_trait]
impl Provider for DevinAcpProvider {
    fn id(&self) -> &str {
        PROVIDER_ID
    }

    fn name(&self) -> &str {
        PROVIDER_NAME
    }

    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        match self.fetch_devin_models().await {
            Ok(models) if !models.is_empty() => Ok(models),
            Ok(_) | Err(_) => Ok(static_models()),
        }
    }

    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let title = title_from_prompt(&req.prompt);
        let (session_id, reply, thinking) =
            self.run_prompt(&req.options, None, req.prompt).await?;

        Ok(StartResponse {
            session_id,
            title,
            reply,
            thinking,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let (_, reply, thinking) = self
            .run_prompt(&req.options, Some(&req.session_id), req.prompt)
            .await?;

        Ok(SendResponse { reply, thinking })
    }

    async fn export(
        &self,
        _session_id: &str,
        _working_dir: &Path,
    ) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
}
