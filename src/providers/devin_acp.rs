//! Devin CLI ACP (Agent Client Protocol) provider.
//!
//! Spawns `devin acp` and communicates over JSON-RPC stdio using the
//! `agent-client-protocol` crate. Permission requests can be forwarded to the
//! API layer through the optional [`SendOptions::permission_callback`]; if no
//! callback is configured, permission requests are rejected.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine as _;
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;

use super::{
    collect_text, collect_thinking, title_from_prompt, Attachment, MessagePart, ModelInfo,
    PartCallback, PartEvent, PermissionCallback, PermissionOption, PermissionOutcome,
    PermissionRequest, Provider, SendOptions, SendRequest, SendResponse, StartRequest,
    StartResponse, ToolCallEvent,
};
use agent_client_protocol::{
    schema::v1::{
        ContentBlock, EmbeddedResourceResource, ImageContent, InitializeRequest,
        LoadSessionRequest, LoadSessionResponse, NewSessionRequest, NewSessionResponse,
        PermissionOption as AcpPermissionOption, PermissionOptionKind as AcpPermissionOptionKind,
        PromptRequest, RequestPermissionOutcome,
        RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
        SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionValue,
        SessionConfigSelectOptions, SessionId, SessionModeId, SessionNotification,
        SetSessionConfigOptionRequest, SetSessionModeRequest, TextContent, ToolCallContent,
        ToolCallLocation, ToolCallStatus, ToolCallUpdate, ToolKind,
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

    /// Prepend a mode instruction to the prompt so the Devin CLI
    /// behaves according to the selected composer mode (plan/ask/code).
    /// This is the fallback for ACP agents that do not expose a native
    /// `interaction_mode` session config option.
    fn apply_interaction_mode_prefix(prompt: String, mode: &str) -> String {
        match mode.trim().to_lowercase().as_str() {
            "plan" => format!(
                "You are in Plan mode. First produce a concise plan and do not \
run tools, edit files, or execute commands until the user confirms.\n\n{prompt}"
            ),
            "ask" => format!(
                "You are in Ask mode. Answer the user's question directly and do \
not use tools, edit files, or execute commands.\n\n{prompt}"
            ),
            _ => prompt,
        }
    }

    /// Map the composer interaction mode to a Devin ACP session mode id.
    /// `code` is sent as `default` to restore the normal builder mode.
    fn devin_mode_id(mode: &str) -> Option<SessionModeId> {
        let id = match mode.trim().to_lowercase().as_str() {
            "ask" => "ask",
            "plan" => "plan",
            "code" => "default",
            _ => "default",
        };
        if id.is_empty() {
            None
        } else {
            Some(SessionModeId::new(id))
        }
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
        let health = Client.builder().name("devinorium").connect_with(
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
}

struct PromptResult {
    session_id: String,
    reply: String,
    thinking: String,
    parts: Vec<MessagePart>,
}

impl DevinAcpProvider {
    async fn run_prompt(
        &self,
        options: &SendOptions,
        maybe_session: Option<&str>,
        prompt: String,
    ) -> anyhow::Result<PromptResult> {
        let parts = Arc::new(Mutex::new(Vec::<MessagePart>::new()));
        let part_callback: Option<PartCallback> = options.part_callback.clone();

        let cwd = options.working_dir.clone();
        let maybe_session = maybe_session.map(|s| s.to_string());
        let permission_callback = options.permission_callback.clone();
        let replaying = Arc::new(AtomicBool::new(maybe_session.is_some()));

        let result = Client
            .builder()
            .name("devinorium")
            .on_receive_notification(
                {
                    let parts = parts.clone();
                    let part_callback = part_callback.clone();
                    let replaying = replaying.clone();
                    async move |notification: SessionNotification, _cx| {
                        if replaying.load(Ordering::SeqCst) {
                            return Ok(());
                        }
                        let mut guard = parts.lock().await;
                        let event = apply_notification(&notification, &mut guard);
                        drop(guard);
                        if let (Some(cb), Some(ev)) = (part_callback.as_ref(), event) {
                            cb(ev);
                        }
                        Ok(())
                    }
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                {
                    let permission_callback = permission_callback.clone();
                    let replaying = replaying.clone();
                    let permission_mode = options.permission_mode.clone();
                    async move |request: RequestPermissionRequest, responder, _cx| {
                        if replaying.load(Ordering::SeqCst) {
                            responder.respond(RequestPermissionResponse::new(
                                RequestPermissionOutcome::Cancelled,
                            ))
                        } else {
                            let outcome = handle_permission_request(
                                request,
                                &permission_mode,
                                permission_callback.as_ref(),
                            )
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

                    if let Some(mode_id) = Self::devin_mode_id(&options.interaction_mode) {
                        if let Err(e) = connection
                            .send_request(SetSessionModeRequest::new(
                                SessionId::new(session_id.clone()),
                                mode_id,
                            ))
                            .block_task()
                            .await
                        {
                            tracing::warn!(
                                session_id = %session_id,
                                error = %e,
                                "failed to set devin acp session mode"
                            );
                        }
                    }

                    let prompt =
                        Self::apply_interaction_mode_prefix(prompt, &options.interaction_mode);

                    let mut prompt_blocks = vec![ContentBlock::Text(TextContent::new(prompt))];
                    prompt_blocks.extend(
                        self.attachment_blocks(&options.attachments, &options.working_dir)
                            .await?,
                    );

                    replaying.store(false, Ordering::SeqCst);
                    let _prompt_response = connection
                        .send_request(PromptRequest::new(session_id.clone(), prompt_blocks))
                        .block_task()
                        .await?;

                    let parts = parts.lock().await.clone();
                    let reply = collect_text(&parts);
                    let thinking = collect_thinking(&parts);

                    Ok::<_, agent_client_protocol::Error>(PromptResult {
                        session_id,
                        reply,
                        thinking,
                        parts,
                    })
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
                blocks.push(ContentBlock::Image(ImageContent::new(
                    b64,
                    att.mime.clone(),
                )));
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

    let fallback = std::env::temp_dir()
        .join("devinorium-attachments")
        .join(format!("{}-{}", std::process::id(), uuid::Uuid::new_v4()));
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

    if let Some(interaction_opt) = config_options
        .iter()
        .find(|o| o.id.0.as_ref() == "interaction_mode")
    {
        let choices = select_values(interaction_opt);
        let requested = options.interaction_mode.trim();
        let mut value = if choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if requested == "code" {
            // Providers expose the default builder mode under different names.
            if let Some(v) = choices.iter().find(|v| *v == "default" || *v == "build") {
                tracing::info!(
                    session_id = %session_id,
                    requested = %requested,
                    value = %v,
                    "mapping code interaction mode to provider value"
                );
                v.clone()
            } else {
                requested.to_string()
            }
        } else {
            requested.to_string()
        };

        if !choices.iter().any(|v| v.as_str() == value) {
            if let Some(first) = choices.first() {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    value = %first,
                    "interaction mode not in ACP choices, using fallback"
                );
                value = first.clone();
            } else {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    "ACP agent has no interaction mode choices, skipping"
                );
            }
        }

        if choices.iter().any(|v| v.as_str() == value) {
            tracing::info!(session_id = %session_id, value = %value, "setting devin acp interaction mode");
            if let Err(e) = connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session_id.clone(),
                    SessionConfigId::new("interaction_mode"),
                    SessionConfigOptionValue::value_id(value),
                ))
                .block_task()
                .await
            {
                tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp interaction mode");
            }
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
    permission_mode: &str,
    permission_callback: Option<&PermissionCallback>,
) -> RequestPermissionOutcome {
    if is_bypass_mode(permission_mode) {
        if let Some(option) = select_allow_option(&request.options) {
            tracing::info!(
                scope = %request.tool_call.tool_call_id,
                option_id = %option.option_id,
                "auto-allowing permission request in bypass mode"
            );
            return RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                option.option_id.clone(),
            ));
        }
        tracing::warn!(
            scope = %request.tool_call.tool_call_id,
            "bypass mode but no allow option found; forwarding to permission callback"
        );
    }

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

fn is_bypass_mode(mode: &str) -> bool {
    matches!(mode.trim().to_lowercase().as_str(), "bypass" | "yolo")
}

fn select_allow_option(options: &[AcpPermissionOption]) -> Option<&AcpPermissionOption> {
    options
        .iter()
        .find(|o| matches!(o.kind, AcpPermissionOptionKind::AllowOnce))
        .or_else(|| options.iter().find(|o| matches!(o.kind, AcpPermissionOptionKind::AllowAlways)))
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

fn apply_notification(
    notification: &SessionNotification,
    parts: &mut Vec<MessagePart>,
) -> Option<PartEvent> {
    use agent_client_protocol::schema::v1::SessionUpdate;
    match &notification.update {
        SessionUpdate::AgentMessageChunk(chunk) => {
            text_from_content_block(&chunk.content).map(|text| {
                let part = MessagePart::text(text);
                parts.push(part.clone());
                PartEvent::New(part)
            })
        }
        SessionUpdate::AgentThoughtChunk(chunk) => {
            text_from_content_block(&chunk.content).map(|text| {
                let part = MessagePart::thinking(text);
                parts.push(part.clone());
                PartEvent::New(part)
            })
        }
        SessionUpdate::ToolCall(tool_call) => {
            let id = tool_call.tool_call_id.to_string();
            if let Some(idx) = parts.iter().position(|p| p.tool_id() == Some(id.as_str())) {
                let existing = match &parts[idx] {
                    MessagePart::ToolCall { payload } => payload.clone(),
                    _ => return None,
                };
                let merged = merge_tool_call_with_existing(&existing, tool_call);
                let part = MessagePart::tool_call(merged);
                parts[idx] = part.clone();
                Some(PartEvent::Update(part))
            } else {
                let ev = build_tool_call_event(tool_call);
                let part = MessagePart::tool_call(ev);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
        }
        SessionUpdate::ToolCallUpdate(update) => {
            let update_id = update.tool_call_id.to_string();
            if let Some(idx) = parts
                .iter()
                .position(|p| p.tool_id() == Some(update_id.as_str()))
            {
                let existing = match &parts[idx] {
                    MessagePart::ToolCall { payload } => payload.clone(),
                    _ => return None,
                };
                let updated = merge_tool_call_update(Some(&existing), update);
                let part = MessagePart::tool_call(updated);
                parts[idx] = part.clone();
                Some(PartEvent::Update(part))
            } else {
                let ev = merge_tool_call_update(None, update);
                let part = MessagePart::tool_call(ev);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
        }
        _ => None,
    }
}

fn merge_tool_call_with_existing(
    existing: &ToolCallEvent,
    tool_call: &agent_client_protocol::schema::v1::ToolCall,
) -> ToolCallEvent {
    let mut ev = build_tool_call_event(tool_call);
    if matches!(existing.status.as_str(), "completed" | "failed")
        && !matches!(ev.status.as_str(), "completed" | "failed")
    {
        ev.status = existing.status.clone();
    }
    if ev.output.is_none() {
        ev.output = existing.output.clone();
    }
    if ev.output_preview.is_none() {
        ev.output_preview = existing.output_preview.clone();
    }
    if ev.command.is_none() {
        ev.command = existing.command.clone();
    }
    if ev.changed_files.is_empty() && !existing.changed_files.is_empty() {
        ev.changed_files = existing.changed_files.clone();
    }
    ev
}

fn build_tool_call_event(tool_call: &agent_client_protocol::schema::v1::ToolCall) -> ToolCallEvent {
    let id = tool_call.tool_call_id.to_string();
    let mut ev = build_tool_call_event_core(
        id,
        Some(&tool_call.title),
        Some(tool_call.kind),
        Some(tool_call.status),
        tool_call.raw_input.as_ref(),
        tool_call.raw_output.as_ref(),
        Some(&tool_call.content),
        Some(&tool_call.locations),
    );
    if !matches!(ev.status.as_str(), "completed" | "failed") {
        ev.status = status_to_string(Some(ToolCallStatus::InProgress));
    }
    ev
}

fn merge_tool_call_update(
    existing: Option<&ToolCallEvent>,
    update: &ToolCallUpdate,
) -> ToolCallEvent {
    use agent_client_protocol::schema::v1::ToolCallStatus;

    let title = update
        .fields
        .title
        .as_deref()
        .or(existing.map(|e| e.title.as_str()))
        .filter(|s| !s.is_empty())
        .unwrap_or("Tool call");
    let kind = update
        .fields
        .kind
        .or(existing.map(|e| tool_kind_from_string(&e.kind)))
        .unwrap_or_default();
    let status_opt = update
        .fields
        .status
        .or(existing.and_then(|e| tool_status_from_string(&e.status)));
    let mut status = status_to_string(status_opt);
    if !matches!(status.as_str(), "completed" | "failed") && update.fields.status.is_some() {
        status = status_to_string(Some(ToolCallStatus::InProgress));
    }

    let command = update
        .fields
        .raw_input
        .as_ref()
        .map(json_to_compact_string)
        .or(existing.and_then(|e| e.command.clone()))
        .filter(|s| !s.is_empty());

    let mut output = None;
    let mut changed_files = existing
        .map(|e| e.changed_files.clone())
        .unwrap_or_default();

    if let Some(content) = update.fields.content.as_deref() {
        let (text, changed) = tool_call_output_from_content(content);
        output = text;
        changed_files = changed;
    }

    if let Some(raw_output) = update.fields.raw_output.as_ref() {
        let text = json_to_compact_string(raw_output);
        if !text.is_empty() {
            output = Some(text);
        }
    }

    if output.is_none() {
        output = existing
            .and_then(|e| e.output.clone())
            .filter(|s| !s.is_empty());
    }

    if let Some(locations) = update.fields.locations.as_deref() {
        changed_files = locations
            .iter()
            .map(|l| l.path.to_string_lossy().into_owned())
            .collect();
    }

    let output_preview = output.as_deref().map(|o| truncate_preview(o, 120));

    ToolCallEvent {
        id: update.tool_call_id.to_string(),
        title: title.to_string(),
        kind: kind_to_string(Some(kind)),
        status,
        command,
        output,
        output_preview,
        changed_files,
    }
}

fn build_tool_call_event_core(
    id: impl AsRef<str>,
    title: Option<&str>,
    kind: Option<ToolKind>,
    status: Option<ToolCallStatus>,
    raw_input: Option<&serde_json::Value>,
    raw_output: Option<&serde_json::Value>,
    content: Option<&[ToolCallContent]>,
    locations: Option<&[ToolCallLocation]>,
) -> ToolCallEvent {
    let title = title.filter(|s| !s.is_empty()).unwrap_or("Tool call");
    let status = status_to_string(status);
    let command = raw_input.map(json_to_compact_string);

    let (mut output, mut changed_files) = content
        .map(tool_call_output_from_content)
        .unwrap_or((None, Vec::new()));

    if let Some(raw_output) = raw_output {
        let text = json_to_compact_string(raw_output);
        if !text.is_empty() {
            output = Some(text);
        }
    }

    if let Some(locations) = locations {
        for l in locations {
            changed_files.push(l.path.to_string_lossy().into_owned());
        }
    }

    let output_preview = output.as_deref().map(|o| truncate_preview(o, 120));

    ToolCallEvent {
        id: id.as_ref().to_string(),
        title: title.to_string(),
        kind: kind_to_string(kind),
        status,
        command,
        output,
        output_preview,
        changed_files,
    }
}

fn tool_call_output_from_content(content: &[ToolCallContent]) -> (Option<String>, Vec<String>) {
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
    let output = if output_parts.is_empty() {
        None
    } else {
        Some(output_parts.join(""))
    };
    (output, changed)
}

fn tool_kind_from_string(s: &str) -> ToolKind {
    match s {
        "read" => ToolKind::Read,
        "edit" => ToolKind::Edit,
        "delete" => ToolKind::Delete,
        "move" => ToolKind::Move,
        "search" => ToolKind::Search,
        "execute" => ToolKind::Execute,
        "think" => ToolKind::Think,
        "fetch" => ToolKind::Fetch,
        "switch_mode" => ToolKind::SwitchMode,
        _ => ToolKind::Other,
    }
}

fn tool_status_from_string(s: &str) -> Option<ToolCallStatus> {
    match s {
        "pending" => Some(ToolCallStatus::Pending),
        "in_progress" => Some(ToolCallStatus::InProgress),
        "completed" => Some(ToolCallStatus::Completed),
        "failed" => Some(ToolCallStatus::Failed),
        _ => None,
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
    match s.char_indices().nth(max_len) {
        Some((idx, _)) => format!("{}...", &s[..idx]),
        None => s.to_string(),
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
        let result = self.run_prompt(&req.options, None, req.prompt).await?;

        Ok(StartResponse {
            session_id: result.session_id,
            title,
            reply: result.reply,
            thinking: result.thinking,
            parts: result.parts,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let result = self
            .run_prompt(&req.options, Some(&req.session_id), req.prompt)
            .await?;

        Ok(SendResponse {
            reply: result.reply,
            thinking: result.thinking,
            parts: result.parts,
        })
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
    use std::sync::atomic::{AtomicBool, Ordering};

    fn provider() -> DevinAcpProvider {
        DevinAcpProvider::new("devin".into(), "swe-1-7".into())
    }

    fn note(text: &str) -> SessionNotification {
        use agent_client_protocol::schema::v1::{ContentChunk, SessionUpdate};
        SessionNotification::new(
            "session",
            SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))),
        )
    }

    fn thought(text: &str) -> SessionNotification {
        use agent_client_protocol::schema::v1::{ContentChunk, SessionUpdate};
        SessionNotification::new(
            "session",
            SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))),
        )
    }

    fn tool_call(id: &str, title: &str) -> SessionNotification {
        use agent_client_protocol::schema::v1::SessionUpdate;
        SessionNotification::new(
            "session",
            SessionUpdate::ToolCall(
                agent_client_protocol::schema::v1::ToolCall::new(id.to_string(), title.to_string())
                    .kind(ToolKind::Read),
            ),
        )
    }

    fn tool_update(id: &str, status: ToolCallStatus, output: &str) -> SessionNotification {
        use agent_client_protocol::schema::v1::{SessionUpdate, ToolCallUpdateFields};
        SessionNotification::new(
            "session",
            SessionUpdate::ToolCallUpdate(agent_client_protocol::schema::v1::ToolCallUpdate::new(
                id.to_string(),
                ToolCallUpdateFields::new()
                    .status(status)
                    .raw_output(serde_json::Value::String(output.into())),
            )),
        )
    }

    #[test]
    fn parts_keep_text_thinking_tool_order() {
        let mut parts = Vec::new();
        apply_notification(&note("hello "), &mut parts);
        apply_notification(&thought("hmm"), &mut parts);
        apply_notification(&note("world"), &mut parts);
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);

        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], MessagePart::text("hello "));
        assert_eq!(parts[1], MessagePart::thinking("hmm"));
        assert_eq!(parts[2], MessagePart::text("world"));
        assert!(matches!(&parts[3], MessagePart::ToolCall { payload } if payload.id == "tc-1"));
        assert_eq!(collect_text(&parts), "hello world");
        assert_eq!(collect_thinking(&parts), "hmm");
    }

    #[test]
    fn tool_call_update_before_initial_call_does_not_duplicate() {
        let mut parts = Vec::new();
        apply_notification(
            &tool_update("tc-1", ToolCallStatus::Completed, "ok"),
            &mut parts,
        );
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);

        assert_eq!(parts.len(), 1);
        assert!(
            matches!(&parts[0], MessagePart::ToolCall { payload } if payload.id == "tc-1" && payload.title == "Read main.rs" && payload.output.as_deref() == Some("ok")),
            "update before the initial call should still resolve to a single part"
        );
    }

    #[test]
    fn tool_call_update_maps_to_same_index() {
        let mut parts = Vec::new();
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);
        apply_notification(&note("found it"), &mut parts);
        apply_notification(
            &tool_update("tc-1", ToolCallStatus::Completed, "ok"),
            &mut parts,
        );

        assert_eq!(parts.len(), 2);
        let first = &parts[0];
        assert!(
            matches!(first, MessagePart::ToolCall { payload } if payload.id == "tc-1" && payload.status == "completed" && payload.output.as_deref() == Some("ok")),
            "tool call update should replace the original part in place"
        );
        assert_eq!(parts[1], MessagePart::text("found it"));
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
        assert_eq!(
            img.data,
            base64::engine::general_purpose::STANDARD.encode(&png)
        );
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

    #[test]
    fn devin_mode_id_maps_interaction_modes() {
        assert_eq!(DevinAcpProvider::devin_mode_id("plan").unwrap().0.as_ref(), "plan");
        assert_eq!(DevinAcpProvider::devin_mode_id("ask").unwrap().0.as_ref(), "ask");
        assert_eq!(DevinAcpProvider::devin_mode_id("code").unwrap().0.as_ref(), "default");
        assert_eq!(DevinAcpProvider::devin_mode_id("unknown").unwrap().0.as_ref(), "default");
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_plan_instruction() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("hello".into(), "plan");
        assert!(out.contains("Plan mode"));
        assert!(out.contains("hello"));
        assert!(out.contains("do not run tools"));
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_ask_instruction() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("hi".into(), "ask");
        assert!(out.contains("Ask mode"));
        assert!(out.contains("hi"));
        assert!(out.contains("do not use tools"));
    }

    #[test]
    fn apply_interaction_mode_prefix_leaves_code_prompt_unchanged() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("go".into(), "code");
        assert_eq!(out, "go");
    }

    #[test]
    fn truncate_preview_respects_char_boundaries() {
        assert_eq!(truncate_preview("hello world", 5), "hello...");

        let cjk = "这是一个中文字符串";
        assert_eq!(truncate_preview(cjk, 5), "这是一个中...");

        let emoji = "🌍🌎🌏🚀✨";
        assert_eq!(truncate_preview(emoji, 3), "🌍🌎🌏...");

        let mixed = "hello 世界 🌍 more";
        assert_eq!(truncate_preview(mixed, 8), "hello 世界...");
    }

    #[test]
    fn tool_call_output_from_content_handles_chinese() {
        let text = "中文工具输出";
        let content = vec![ToolCallContent::from(ContentBlock::Text(TextContent::new(text)))];
        let (output, changed) = tool_call_output_from_content(&content);
        assert_eq!(output.as_deref(), Some(text));
        assert!(changed.is_empty());
    }

    #[test]
    fn merge_tool_call_update_truncates_chinese_preview() {
        use agent_client_protocol::schema::v1::ToolCallUpdateFields;

        let long = "这是一个测试".repeat(25);
        let content = vec![ToolCallContent::from(ContentBlock::Text(TextContent::new(&long)))];
        let update = ToolCallUpdate::new(
            "tc-1",
            ToolCallUpdateFields::new()
                .status(ToolCallStatus::Completed)
                .content(content),
        );

        let event = merge_tool_call_update(None, &update);
        assert_eq!(event.output.as_deref(), Some(long.as_str()));

        let preview = event.output_preview.expect("preview should be set");
        assert_eq!(preview, "这是一个测试".repeat(20) + "...");
        assert_eq!(preview.chars().count(), 123);
    }

    fn make_permission_request(options: Vec<AcpPermissionOption>) -> RequestPermissionRequest {
        use agent_client_protocol::schema::v1::ToolCallUpdateFields;
        RequestPermissionRequest::new(
            SessionId::new("sid"),
            ToolCallUpdate::new("tc-1", ToolCallUpdateFields::new()),
            options,
        )
    }

    fn recording_callback(allowed_id: &'static str, called: Arc<AtomicBool>) -> PermissionCallback {
        Arc::new(move |_req| {
            called.store(true, Ordering::SeqCst);
            Box::pin(async move { PermissionOutcome::Allow { option_id: allowed_id.into() } })
        })
    }

    #[tokio::test]
    async fn bypass_auto_selects_allow_once() {
        let options = vec![
            AcpPermissionOption::new("allow-once", "Allow", AcpPermissionOptionKind::AllowOnce),
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("allow-once", called.clone()));

        let outcome = handle_permission_request(request, "bypass", callback.as_ref()).await;

        assert!(!called.load(Ordering::SeqCst), "callback should not be invoked in bypass mode");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-once");
    }

    #[tokio::test]
    async fn bypass_falls_back_to_allow_always() {
        let options = vec![
            AcpPermissionOption::new("allow-always", "Always", AcpPermissionOptionKind::AllowAlways),
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);

        let outcome = handle_permission_request(request, "bypass", None).await;

        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-always");
    }

    #[tokio::test]
    async fn bypass_falls_back_to_callback_when_no_allow_option() {
        let options = vec![
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("reject", called.clone()));

        let outcome = handle_permission_request(request, "bypass", callback.as_ref()).await;

        assert!(called.load(Ordering::SeqCst), "callback should be invoked when no allow option");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "reject");
    }

    #[tokio::test]
    async fn normal_mode_forwards_to_callback() {
        let options = vec![
            AcpPermissionOption::new("allow-once", "Allow", AcpPermissionOptionKind::AllowOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("allow-once", called.clone()));

        let outcome = handle_permission_request(request, "normal", callback.as_ref()).await;

        assert!(called.load(Ordering::SeqCst), "callback should be invoked in normal mode");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-once");
    }

    #[tokio::test]
    async fn yolo_is_treated_as_bypass() {
        let options = vec![
            AcpPermissionOption::new("allow-always", "Always", AcpPermissionOptionKind::AllowAlways),
        ];
        let request = make_permission_request(options);

        let outcome = handle_permission_request(request, " yolo ", None).await;

        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-always");
    }
}
