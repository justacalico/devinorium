//! Devin CLI ACP (Agent Client Protocol) provider.
//!
//! Spawns `devin acp` and communicates over JSON-RPC stdio using the
//! `agent-client-protocol` crate. Permission requests can be forwarded to the
//! API layer through the optional [`SendOptions::permission_callback`]; if no
//! callback is configured, permission requests are rejected.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine as _;
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;

use super::{
    title_from_prompt, Attachment, ModelInfo, PermissionCallback, PermissionOption,
    PermissionOutcome, PermissionRequest, Provider, SendOptions, SendRequest, SendResponse,
    StartRequest, StartResponse, StreamChunkCallback, ToolCallCallback, ToolCallEvent,
};
use agent_client_protocol::{
    schema::v1::{
        ContentBlock, EmbeddedResourceResource, ImageContent, InitializeRequest, LoadSessionRequest,
        LoadSessionResponse, NewSessionRequest, NewSessionResponse,
        PermissionOption as AcpPermissionOption, PromptRequest, RequestPermissionOutcome,
        RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
        SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionValue,
        SessionConfigSelectOptions, SessionId, SessionNotification, SetSessionConfigOptionRequest,
        TextContent, ToolCallContent, ToolCallStatus, ToolKind,
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

    /// Verify the binary is on PATH and the ACP handshake succeeds
    /// without creating a session or sending a prompt.
    pub async fn do_health_check(&self) -> anyhow::Result<()> {
        // First make sure the binary exists.
        let path = tokio::task::spawn_blocking({
            let bin = self.bin.clone();
            move || which::which(&bin)
        })
        .await?;

        if path.is_err() {
            anyhow::bail!("provider command not found: {}", self.bin);
        }

        // Open an ACP connection and send Initialize, with a timeout so the
        // test button can’t hang if the binary is unresponsive.
        let health = Client
            .builder()
            .name("devinorium")
            .connect_with(
                AcpAgent::from_args([&self.bin, "acp"])?,
                async move |connection: ConnectionTo<Agent>| {
                    let _ = connection
                        .send_request(InitializeRequest::new(ProtocolVersion::V1))
                        .block_task()
                        .await?;
                    Ok::<_, agent_client_protocol::Error>(())
                },
            );

        tokio::time::timeout(std::time::Duration::from_secs(15), health)
            .await
            .map_err(|_| anyhow::anyhow!("acp health check timed out"))?
            .map_err(|e| anyhow::anyhow!("acp health check failed: {e}"))?;
        Ok(())
    }

    async fn run_prompt(
        &self,
        options: &SendOptions,
        maybe_session: Option<&str>,
        prompt: String,
    ) -> anyhow::Result<(String, String, String)> {
        let text_acc = Arc::new(Mutex::new(String::new()));
        let thinking_acc = Arc::new(Mutex::new(String::new()));
        let tool_calls: Arc<Mutex<HashMap<String, ToolCallEvent>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let text_callback = options.text_callback.clone();
        let thinking_callback = options.thinking_callback.clone();
        let tool_callback = options.tool_callback.clone();

        let cwd = options.working_dir.clone();
        let maybe_session = maybe_session.map(|s| s.to_string());
        let permission_callback = options.permission_callback.clone();
        let replaying = Arc::new(AtomicBool::new(maybe_session.is_some()));

        let result = Client
            .builder()
            .name("devinorium")
            .on_receive_notification(
                {
                    let text_acc = text_acc.clone();
                    let thinking_acc = thinking_acc.clone();
                    let text_callback = text_callback.clone();
                    let thinking_callback = thinking_callback.clone();
                    let tool_calls = tool_calls.clone();
                    let tool_callback = tool_callback.clone();
                    let replaying = replaying.clone();
                    async move |notification: SessionNotification, _cx| {
                        // Ignore notifications that are part of the session-load replay.
                        // We only want text/thinking/tool-calls from the new prompt.
                        if replaying.load(Ordering::SeqCst) {
                            return Ok(());
                        }
                        let (text, thinking) = extract_text_from_notification(&notification).await;
                        if let Some(t) = text {
                            emit_chunk(&text_acc, text_callback.as_ref(), t).await;
                        }
                        if let Some(t) = thinking {
                            emit_chunk(&thinking_acc, thinking_callback.as_ref(), t).await;
                        }
                        handle_tool_call_notification(
                            &notification,
                            &tool_calls,
                            tool_callback.as_ref(),
                        )
                        .await;
                        Ok(())
                    }
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                {
                    let permission_callback = permission_callback.clone();
                    let replaying = replaying.clone();
                    async move |request: RequestPermissionRequest, responder, _cx| {
                        if replaying.load(Ordering::SeqCst) {
                            responder.respond(RequestPermissionResponse::new(
                                RequestPermissionOutcome::Cancelled,
                            ))
                        } else {
                            let outcome =
                                handle_permission_request(request, permission_callback.as_ref())
                                    .await;
                            responder.respond(RequestPermissionResponse::new(outcome))
                        }
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

                    let mut prompt_blocks = vec![ContentBlock::Text(TextContent::new(prompt))];
                    prompt_blocks.extend(
                        self.attachment_blocks(&options.attachments, &options.working_dir)
                            .await?,
                    );

                    // The session-load replay is over once we send the new prompt.
                    replaying.store(false, Ordering::SeqCst);
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

    async fn attachment_blocks(
        &self,
        attachments: &[Attachment],
        working_dir: &Path,
    ) -> anyhow::Result<Vec<ContentBlock>> {
        if attachments.is_empty() {
            return Ok(Vec::new());
        }

        // Clients upload attachments as raw bytes, so images can be sent as ACP
        // ContentBlock::Image blocks without touching the filesystem. Non-image files
        // (e.g. skill .md files) still need to be written to a writable directory so
        // the agent can read them via @path; if the project's working directory is not
        // writable we fall back to a process-scoped temp directory.
        let att_dir = ensure_writable_attachment_dir(working_dir).await?;
        let mut blocks = Vec::new();

        for (i, att) in attachments.iter().enumerate() {
            if att.mime.starts_with("image/") && !att.mime.ends_with("svg+xml") {
                let b64 = base64::engine::general_purpose::STANDARD.encode(&att.data);
                blocks.push(ContentBlock::Image(ImageContent::new(b64, att.mime.clone())));
            } else {
                let name = format!("{}_{}", i, sanitize(&att.filename));
                let path = att_dir.join(&name);
                tokio::fs::write(&path, &att.data).await?;
                blocks.push(ContentBlock::Text(TextContent::new(format!(
                    "\n\n[Attachment {}: {} ({} bytes)]\n@{}\n",
                    i,
                    att.filename,
                    att.data.len(),
                    path.display()
                ))));
            }
        }

        Ok(blocks)
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
            #[serde(default)]
            cost_summary: String,
            #[serde(default)]
            max_context_tokens: u64,
            #[serde(default)]
            max_output_tokens: u64,
            #[serde(default)]
            is_new: bool,
            #[serde(default)]
            is_beta: bool,
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
                    cost_summary: v.cost_summary,
                    max_context_tokens: v.max_context_tokens,
                    max_output_tokens: v.max_output_tokens,
                    is_new: v.is_new,
                    is_beta: v.is_beta,
                });
            }
        }

        Ok(models)
    }
}

async fn ensure_writable_attachment_dir(working_dir: &Path) -> anyhow::Result<PathBuf> {
    let preferred = working_dir.join(".devinorium-attachments");
    if tokio::fs::create_dir_all(&preferred).await.is_ok() {
        let probe = preferred.join(format!(".probe-{}", uuid::Uuid::new_v4()));
        if tokio::fs::write(&probe, b"").await.is_ok() {
            let _ = tokio::fs::remove_file(&probe).await;
            return Ok(preferred);
        }
    }

    let fallback = std::env::temp_dir().join("devinorium-attachments").join(format!(
        "{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    tokio::fs::create_dir_all(&fallback).await?;
    Ok(fallback)
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
        SessionUpdate::ToolCall(_) | SessionUpdate::ToolCallUpdate(_) => (None, None),
        _ => (None, None),
    }
}

async fn handle_tool_call_notification(
    notification: &SessionNotification,
    tool_calls: &Mutex<HashMap<String, ToolCallEvent>>,
    callback: Option<&ToolCallCallback>,
) {
    use agent_client_protocol::schema::v1::{SessionUpdate, ToolCallStatus};

    let (id, title, kind, status, raw_input, raw_output, content) = match &notification.update {
        SessionUpdate::ToolCall(tool_call) => (
            tool_call.tool_call_id.to_string(),
            Some(tool_call.title.clone()),
            Some(tool_call.kind),
            Some(tool_call.status),
            tool_call.raw_input.clone(),
            tool_call.raw_output.clone(),
            Some(tool_call.content.clone()),
        ),
        SessionUpdate::ToolCallUpdate(update) => {
            let f = &update.fields;
            (
                update.tool_call_id.to_string(),
                f.title.clone(),
                f.kind,
                f.status,
                f.raw_input.clone(),
                f.raw_output.clone(),
                f.content.clone(),
            )
        }
        _ => return,
    };

    let mut map = tool_calls.lock().await;
    let existing = map.get(&id).cloned();
    let mut ev = existing.unwrap_or_else(|| ToolCallEvent {
        id: id.clone(),
        title: title.clone().unwrap_or_else(|| "Tool call".to_string()),
        kind: kind_to_string(None),
        status: status_to_string(None),
        command: None,
        output: None,
        output_preview: None,
        changed_files: Vec::new(),
    });

    if let Some(t) = title {
        ev.title = t;
    }
    if let Some(k) = kind {
        ev.kind = kind_to_string(Some(k));
    }
    if let Some(s) = status {
        ev.status = status_to_string(Some(s));
    } else if ev.status.is_empty() {
        ev.status = status_to_string(None);
    }

    if let Some(input) = raw_input {
        ev.command = Some(json_to_compact_string(&input));
    }
    if let Some(output) = raw_output {
        let text = json_to_compact_string(&output);
        if !text.is_empty() {
            ev.output = Some(text);
        }
    }

    if let Some(content) = content {
        let mut output_parts = Vec::new();
        let mut changed = Vec::new();
        for c in content {
            match c {
                ToolCallContent::Content(content) => {
                    if let Some(text) = text_from_content_block(&content.content) {
                        output_parts.push(text);
                    }
                }
                ToolCallContent::Diff(diff) => {
                    changed.push(diff.path.to_string_lossy().into_owned());
                }
                _ => {}
            }
        }
        if !output_parts.is_empty() {
            let text = output_parts.join("");
            ev.output = Some(text);
        }
        if !changed.is_empty() {
            ev.changed_files = changed;
        }
    }

    if let Some(output) = ev.output.as_deref() {
        ev.output_preview = Some(truncate_preview(output, 120));
    }

    // Treat any non-terminal status as "in progress" until completed/failed.
    if !matches!(ev.status.as_str(), "completed" | "failed") && status.is_some() {
        ev.status = status_to_string(Some(ToolCallStatus::InProgress));
    }

    map.insert(id, ev.clone());
    if let Some(cb) = callback {
        cb(ev);
    }
}

fn kind_to_string(kind: Option<ToolKind>) -> String {
    use ToolKind;
    match kind {
        Some(ToolKind::Read) => "read".to_string(),
        Some(ToolKind::Edit) => "edit".to_string(),
        Some(ToolKind::Delete) => "delete".to_string(),
        Some(ToolKind::Move) => "move".to_string(),
        Some(ToolKind::Search) => "search".to_string(),
        Some(ToolKind::Execute) => "execute".to_string(),
        Some(ToolKind::Think) => "think".to_string(),
        Some(ToolKind::Fetch) => "fetch".to_string(),
        Some(ToolKind::SwitchMode) => "switch_mode".to_string(),
        Some(ToolKind::Other) | None => "other".to_string(),
        Some(_) => "other".to_string(),
    }
}

fn status_to_string(status: Option<ToolCallStatus>) -> String {
    match status {
        Some(ToolCallStatus::Pending) => "pending".to_string(),
        Some(ToolCallStatus::InProgress) => "in_progress".to_string(),
        Some(ToolCallStatus::Completed) => "completed".to_string(),
        Some(ToolCallStatus::Failed) => "failed".to_string(),
        Some(_) => "in_progress".to_string(),
        None => "in_progress".to_string(),
    }
}

fn json_to_compact_string(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        _ => serde_json::to_string(value).unwrap_or_default(),
    }
}

fn truncate_preview(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len])
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
            cost_summary: "Free".into(),
            max_context_tokens: 1_000_000,
            max_output_tokens: 128_000,
            is_new: false,
            is_beta: false,
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

    async fn health_check(&self) -> anyhow::Result<()> {
        self.do_health_check().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn provider() -> DevinAcpProvider {
        DevinAcpProvider::new("devin".into(), "swe-1-7".into())
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn fallback_to_temp_when_working_dir_not_writable() {
        let root = tempfile::tempdir().unwrap();
        let locked = root.path().join("locked");
        fs::create_dir(&locked).unwrap();
        fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555)).unwrap();

        let dir = ensure_writable_attachment_dir(&locked).await.unwrap();
        assert!(dir.starts_with(std::env::temp_dir()));

        // Restore permissions so tempdir cleanup can remove the root.
        fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[tokio::test]
    async fn image_attachment_produces_image_block() {
        let root = tempfile::tempdir().unwrap();
        let png = vec![0x89, 0x50, 0x4e, 0x47];
        let attachments = vec![Attachment {
            filename: "pixel.png".into(),
            mime: "image/png".into(),
            data: png.clone(),
        }];

        let blocks = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();

        assert_eq!(blocks.len(), 1);
        let ContentBlock::Image(img) = &blocks[0] else {
            panic!("expected image block, got {:?}", blocks[0]);
        };
        assert_eq!(img.data, base64::engine::general_purpose::STANDARD.encode(&png));
        assert_eq!(img.mime_type, "image/png");
    }

    #[tokio::test]
    async fn text_attachment_is_written_and_referenced() {
        let root = tempfile::tempdir().unwrap();
        let attachments = vec![Attachment {
            filename: "secret.txt".into(),
            mime: "text/plain".into(),
            data: b"PINEAPPLE".to_vec(),
        }];

        let blocks = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();

        assert_eq!(blocks.len(), 1);
        let ContentBlock::Text(text) = &blocks[0] else {
            panic!("expected text block, got {:?}", blocks[0]);
        };
        assert!(text.text.contains("@"));
        assert!(text.text.contains("secret.txt"));

        // The file should have been written under the working dir.
        let att_dir = root.path().join(".devinorium-attachments");
        let entries: Vec<_> = fs::read_dir(&att_dir).unwrap().flatten().collect();
        assert_eq!(entries.len(), 1);
        let content = fs::read_to_string(entries[0].path()).unwrap();
        assert_eq!(content, "PINEAPPLE");
    }

    #[tokio::test]
    async fn empty_attachments_returns_empty_blocks() {
        let blocks = provider()
            .attachment_blocks(&[], std::env::temp_dir().as_path())
            .await
            .unwrap();
        assert!(blocks.is_empty());
    }

    #[tokio::test]
    async fn svg_attachment_is_written_not_embedded() {
        let root = tempfile::tempdir().unwrap();
        let svg = b"<svg></svg>".to_vec();
        let attachments = vec![Attachment {
            filename: "icon.svg".into(),
            mime: "image/svg+xml".into(),
            data: svg,
        }];

        let blocks = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();

        assert_eq!(blocks.len(), 1);
        assert!(
            matches!(blocks[0], ContentBlock::Text(_)),
            "SVG files should be written as text attachments, got {:?}",
            blocks[0]
        );
    }

    #[tokio::test]
    async fn multiple_attachments_use_unique_names() {
        let root = tempfile::tempdir().unwrap();
        let attachments = vec![
            Attachment {
                filename: "a.txt".into(),
                mime: "text/plain".into(),
                data: b"first".to_vec(),
            },
            Attachment {
                filename: "a.txt".into(),
                mime: "text/plain".into(),
                data: b"second".to_vec(),
            },
        ];

        let blocks = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();

        assert_eq!(blocks.len(), 2);
        let ContentBlock::Text(first) = &blocks[0] else {
            panic!("expected text block");
        };
        let ContentBlock::Text(second) = &blocks[1] else {
            panic!("expected text block");
        };

        // Each block should reference a distinct filename.
        assert_ne!(first.text, second.text);

        let att_dir = root.path().join(".devinorium-attachments");
        let entries: Vec<_> = fs::read_dir(&att_dir).unwrap().flatten().collect();
        assert_eq!(entries.len(), 2);
    }
}
