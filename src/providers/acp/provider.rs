//! ACP (Agent Client Protocol) provider.
//!
//! Spawns `<bin> acp` and communicates over JSON-RPC stdio using the
//! `agent-client-protocol` crate. The per-agent differences (Devin CLI,
//! OpenCode) live in [`super::spec`]. Permission requests can be forwarded to
//! the API layer through the optional [`SendOptions::permission_callback`]; if
//! no callback is configured, permission requests are rejected.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine as _;
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::Mutex;

use agent_client_protocol::{
    schema::v1::{
        ClientCapabilities, ContentBlock, CreateElicitationRequest, CreateElicitationResponse,
        ElicitationAction, ElicitationCapabilities, ElicitationFormCapabilities, ImageContent,
        InitializeRequest, LoadSessionRequest, NewSessionRequest, NewSessionResponse,
        PromptRequest, RequestPermissionOutcome, RequestPermissionRequest,
        RequestPermissionResponse, SessionConfigOption, SessionId, SessionNotification,
        SessionUpdate, SetSessionModeRequest, TextContent,
    },
    schema::ProtocolVersion as ProtocolVersionEnum,
    AcpAgent, Agent, Client, ConnectionTo,
};

use super::{
    content::sanitize, elicitation::handle_ask_request, models,
    permissions::handle_permission_request, session_config::apply_session_config, spec::AgentKind,
    tool_calls::apply_notification,
};
use crate::providers::{
    collect_text, collect_thinking, title_from_prompt, Attachment, MessagePart, ModelInfo,
    PartCallback, Provider, SendOptions, SendRequest, SendResponse, StartRequest, StartResponse,
    UsageSnapshot,
};

pub struct AcpProvider {
    pub(crate) kind: AgentKind,
    pub(crate) bin: String,
    default_model: String,
}

impl AcpProvider {
    pub fn new(kind: AgentKind, bin: String, default_model: String) -> Self {
        Self {
            kind,
            bin,
            default_model,
        }
    }

    /// argv that starts the agent's ACP stdio server.
    pub(crate) fn agent_args(&self) -> Vec<String> {
        std::iter::once(self.bin.clone())
            .chain(self.kind.acp_args().iter().map(|s| s.to_string()))
            .collect()
    }

    /// The thread's permission allowlist reaches the Devin agent through its
    /// user config: the child gets `XDG_CONFIG_HOME` pointing at a temp root
    /// whose `devin/config.json` is the user's real config plus the thread
    /// rules, and every other entry under the real config root is symlinked
    /// in so nothing else changes. The temp root self-cleans when the turn
    /// ends. Returns the env args to prepend and the guard holding the dir.
    async fn permission_config_env(
        &self,
        options: &SendOptions,
    ) -> anyhow::Result<(Vec<String>, Option<tempfile::TempDir>)> {
        if self.kind != AgentKind::Devin {
            return Ok((Vec::new(), None));
        }
        let rules = parse_permission_rules(options.permissions.as_deref());
        if rules.is_empty() {
            return Ok((Vec::new(), None));
        }
        let Some(real_root) = real_config_root() else {
            return Ok((Vec::new(), None));
        };
        let Some(temp) = write_permission_config(&real_root, &rules).await? else {
            return Ok((Vec::new(), None));
        };
        Ok((
            vec![format!("XDG_CONFIG_HOME={}", temp.path().display())],
            Some(temp),
        ))
    }

    /// Verify the binary is on PATH and the ACP handshake succeeds
    /// without creating a session or sending a prompt.
    pub async fn do_health_check(&self) -> anyhow::Result<()> {
        let path = tokio::task::spawn_blocking({
            let bin = self.bin.clone();
            move || which::which(&bin)
        })
        .await?;

        if path.is_err() {
            anyhow::bail!("provider command not found: {}", self.bin);
        }

        let health = Client.builder().name("devinorium").connect_with(
            AcpAgent::from_args(self.agent_args())?,
            async move |connection: ConnectionTo<Agent>| {
                let _ = connection
                    .send_request(
                        InitializeRequest::new(ProtocolVersionEnum::V1)
                            .client_capabilities(client_capabilities()),
                    )
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
    usage: Option<UsageSnapshot>,
}

async fn cancel_wait(flag: Arc<AtomicBool>) {
    while !flag.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

impl AcpProvider {
    async fn run_prompt(
        &self,
        options: &SendOptions,
        maybe_session: Option<&str>,
        prompt: String,
    ) -> anyhow::Result<PromptResult> {
        let parts = Arc::new(Mutex::new(Vec::<MessagePart>::new()));
        let part_callback: Option<PartCallback> = options.part_callback.clone();
        // Latest cumulative session cost reported via `usage_update`
        // notifications during this prompt turn.
        let turn_cost = Arc::new(Mutex::new(None::<(f64, String)>));

        let cwd = options.working_dir.clone();
        let maybe_session = maybe_session.map(|s| s.to_string());
        let permission_callback = options.permission_callback.clone();
        let ask_callback = options.ask_callback.clone();
        let cancel_signal = options.cancel_signal.clone();
        let replaying = Arc::new(AtomicBool::new(maybe_session.is_some()));

        let (env_args, _perm_cfg) = self.permission_config_env(options).await?;
        let agent_args: Vec<String> = env_args.into_iter().chain(self.agent_args()).collect();

        let result = Client
            .builder()
            .name("devinorium")
            .on_receive_notification(
                {
                    let parts = parts.clone();
                    let part_callback = part_callback.clone();
                    let replaying = replaying.clone();
                    let turn_cost = turn_cost.clone();
                    async move |notification: SessionNotification, _cx| {
                        if replaying.load(Ordering::SeqCst) {
                            return Ok(());
                        }
                        if let SessionUpdate::UsageUpdate(u) = &notification.update {
                            if let Some(cost) = &u.cost {
                                *turn_cost.lock().await =
                                    Some((cost.amount, cost.currency.clone()));
                            }
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
            .on_receive_request(
                {
                    let ask_callback = ask_callback.clone();
                    let replaying = replaying.clone();
                    async move |request: CreateElicitationRequest, responder, _cx| {
                        let response = if replaying.load(Ordering::SeqCst) {
                            CreateElicitationResponse::new(ElicitationAction::Cancel)
                        } else {
                            handle_ask_request(request, ask_callback.as_ref()).await
                        };
                        responder.respond(response)
                    }
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_with(
                AcpAgent::from_args(agent_args)?,
                async move |connection: ConnectionTo<Agent>| {
                    let init_response = connection
                        .send_request(
                            InitializeRequest::new(ProtocolVersionEnum::V1)
                                .client_capabilities(client_capabilities()),
                        )
                        .block_task()
                        .await?;

                    // `session/load` only exists when the agent advertises
                    // `loadSession`, and even then a stored session may be
                    // gone (agent restart, expired history). Fall back to a
                    // fresh session and persist the new id.
                    let can_load =
                        maybe_session.is_some() && init_response.agent_capabilities.load_session;
                    if maybe_session.is_some() && !can_load {
                        tracing::info!(
                            "acp agent does not support session/load; starting a new session"
                        );
                    }

                    let (session_id, config_options) = if can_load {
                        let sid = maybe_session.as_deref().unwrap();
                        match connection
                            .send_request(LoadSessionRequest::new(
                                SessionId::new(sid.to_string()),
                                cwd.clone(),
                            ))
                            .block_task()
                            .await
                        {
                            Ok(load_resp) => (sid.to_string(), load_resp.config_options),
                            Err(e) => {
                                tracing::warn!(
                                    session_id = %sid,
                                    error = %e,
                                    "acp session/load failed; starting a new session"
                                );
                                new_session(&connection, &cwd).await?
                            }
                        }
                    } else {
                        new_session(&connection, &cwd).await?
                    };

                    // Persist the session id when it differs from the stored
                    // one: a fresh session, or a fallback after a failed or
                    // unsupported load.
                    if maybe_session.as_deref() != Some(session_id.as_str()) {
                        if let Some(ref cb) = options.session_callback {
                            cb(session_id.clone()).await;
                        }
                    }

                    apply_session_config(
                        &connection,
                        &session_id,
                        self.kind,
                        &self.default_model,
                        options,
                        config_options.as_deref(),
                    )
                    .await?;

                    if let Some(mode_id) = self.kind.session_mode_id(&options.interaction_mode) {
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
                                provider = %self.kind.id(),
                                error = %e,
                                "failed to set acp session mode"
                            );
                        }
                    }

                    let prompt =
                        Self::apply_interaction_mode_prefix(prompt, &options.interaction_mode);

                    let mut prompt_blocks = vec![ContentBlock::Text(TextContent::new(prompt))];
                    let (attachment_blocks, _staged) = self
                        .attachment_blocks(&options.attachments, &options.working_dir)
                        .await?;
                    prompt_blocks.extend(attachment_blocks);

                    replaying.store(false, Ordering::SeqCst);
                    let sent = connection
                        .send_request(PromptRequest::new(session_id.clone(), prompt_blocks));
                    let prompt_result = if let Some(ref cancel) = cancel_signal {
                        let cancel_clone = cancel.clone();
                        tokio::select! {
                            r = sent.block_task() => r,
                            _ = cancel_wait(cancel_clone) => {
                                Err(agent_client_protocol::Error::request_cancelled())
                            }
                        }
                    } else {
                        sent.block_task().await
                    };

                    if let Err(e) = &prompt_result {
                        if !cancel_signal
                            .as_ref()
                            .map(|c| c.load(Ordering::SeqCst))
                            .unwrap_or(false)
                        {
                            return Err(e.clone());
                        }
                        tracing::debug!(error = %e, "prompt cancelled by user");
                    }

                    let usage = prompt_result
                        .as_ref()
                        .ok()
                        .and_then(|resp| resp.usage.as_ref())
                        .map(usage_from_acp);
                    let cost = turn_cost.lock().await.clone();
                    let usage = match (usage, cost) {
                        (Some(mut u), Some((amount, currency))) => {
                            u.cost_amount = Some(amount);
                            u.cost_currency = Some(currency);
                            Some(u)
                        }
                        (Some(u), None) => Some(u),
                        (None, Some((amount, currency))) => Some(UsageSnapshot {
                            cost_amount: Some(amount),
                            cost_currency: Some(currency),
                            ..UsageSnapshot::default()
                        }),
                        (None, None) => None,
                    };

                    let parts = parts.lock().await.clone();
                    let reply = collect_text(&parts);
                    let thinking = collect_thinking(&parts);

                    Ok::<_, agent_client_protocol::Error>(PromptResult {
                        session_id,
                        reply,
                        thinking,
                        parts,
                        usage,
                    })
                },
            )
            .await
            .map_err(|e| anyhow::anyhow!("acp connection failed: {e}"));

        result
    }

    /// Stage non-image attachments to disk and build the prompt blocks that
    /// reference them. The returned guard removes the staging dir when the
    /// turn ends (or when a write fails mid-way and the error propagates).
    async fn attachment_blocks(
        &self,
        attachments: &[Attachment],
        working_dir: &Path,
    ) -> anyhow::Result<(Vec<ContentBlock>, StagedAttachments)> {
        if attachments.is_empty() {
            return Ok((Vec::new(), StagedAttachments::none()));
        }

        let att_dir = ensure_writable_attachment_dir(working_dir).await?;
        let staged = StagedAttachments::new(att_dir.clone());
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

        Ok((blocks, staged))
    }

    async fn fetch_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        match self.kind {
            AgentKind::Devin => self.fetch_devin_models().await,
            AgentKind::Opencode => models::fetch_opencode_models(&self.bin).await,
            AgentKind::Grok => models::fetch_grok_models(&self.bin).await,
        }
    }

    async fn fetch_devin_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            Command::new(&self.bin)
                .args(["models", "list", "--format", "json"])
                .current_dir(".")
                .kill_on_drop(true)
                .output(),
        )
        .await
        .map_err(|_| anyhow::anyhow!("devin models list timed out"))??;

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
            #[serde(default)]
            default_reasoning_effort: Option<String>,
            #[serde(default)]
            supported_reasoning_efforts: Vec<String>,
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
                    default_reasoning_effort: v.default_reasoning_effort,
                    supported_reasoning_efforts: v.supported_reasoning_efforts,
                });
            }
        }

        Ok(models)
    }
}

/// Map the cumulative token totals on an ACP `session/prompt` response onto
/// our snapshot type. Agents may omit the field entirely, in which case the
/// caller keeps any cost data captured from `usage_update` notifications.
fn usage_from_acp(usage: &agent_client_protocol::schema::v1::Usage) -> UsageSnapshot {
    UsageSnapshot {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        thought_tokens: usage.thought_tokens.unwrap_or(0),
        cached_read_tokens: usage.cached_read_tokens.unwrap_or(0),
        cached_write_tokens: usage.cached_write_tokens.unwrap_or(0),
        total_tokens: usage.total_tokens,
        cost_amount: None,
        cost_currency: None,
    }
}

pub(crate) async fn ensure_writable_attachment_dir(working_dir: &Path) -> anyhow::Result<PathBuf> {
    // A fresh subdirectory per turn so cleanup can remove it wholesale
    // without touching files a concurrent send in the same worktree staged.
    let preferred = working_dir.join(".devinorium-attachments");
    if tokio::fs::create_dir_all(&preferred).await.is_ok() {
        let probe = preferred.join(format!(".probe-{}", uuid::Uuid::new_v4()));
        if tokio::fs::write(&probe, b"").await.is_ok() {
            let _ = tokio::fs::remove_file(&probe).await;
            let dir = preferred.join(uuid::Uuid::new_v4().to_string());
            tokio::fs::create_dir(&dir).await?;
            return Ok(dir);
        }
    }

    let fallback = std::env::temp_dir()
        .join("devinorium-attachments")
        .join(format!("{}-{}", std::process::id(), uuid::Uuid::new_v4()));
    tokio::fs::create_dir_all(&fallback).await?;
    Ok(fallback)
}

/// Removes a turn's attachment staging dir on drop. The agent reads the
/// staged files while the prompt runs, so the guard is dropped only after
/// the turn resolves; the now-empty parent is removed too when possible.
pub(crate) struct StagedAttachments(Option<PathBuf>);

impl StagedAttachments {
    pub(crate) fn none() -> Self {
        Self(None)
    }

    pub(crate) fn new(dir: PathBuf) -> Self {
        Self(Some(dir))
    }
}

impl Drop for StagedAttachments {
    fn drop(&mut self) {
        if let Some(dir) = self.0.take() {
            let _ = std::fs::remove_dir_all(&dir);
            if let Some(parent) = dir.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }
}

pub(crate) fn client_capabilities() -> ClientCapabilities {
    ClientCapabilities::new()
        .elicitation(ElicitationCapabilities::new().form(ElicitationFormCapabilities::new()))
}

async fn new_session(
    connection: &ConnectionTo<Agent>,
    cwd: &Path,
) -> anyhow::Result<(String, Option<Vec<SessionConfigOption>>)> {
    let resp: NewSessionResponse = connection
        .send_request(NewSessionRequest::new(cwd.to_path_buf()))
        .block_task()
        .await?;
    Ok((resp.session_id.to_string(), resp.config_options))
}

/// Split a thread's allowlist text into rules: entries are comma or
/// newline separated, e.g. "Exec(curl), Fetch(**)".
fn parse_permission_rules(raw: Option<&str>) -> Vec<String> {
    raw.unwrap_or("")
        .split([',', '\n', '\r'])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// The config root devin resolves `devin/config.json` under.
fn real_config_root() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
}

/// Fold `rules` into `config.permissions.allow`, preserving everything else
/// the user configured. Returns false when the existing config cannot be
/// merged safely (unparseable or non-object), in which case the allowlist
/// is not applied rather than clobbering the user's settings.
fn merge_permission_rules(config: &mut serde_json::Value, rules: &[String]) -> bool {
    if !config.is_object() {
        return false;
    }
    let root = config.as_object_mut().unwrap();
    let perms = root
        .entry("permissions".to_string())
        .or_insert_with(|| serde_json::json!({}));
    if !perms.is_object() {
        return false;
    }
    let perms = perms.as_object_mut().unwrap();
    let mut merged: Vec<String> = perms
        .get("allow")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    for rule in rules {
        if !merged.contains(rule) {
            merged.push(rule.clone());
        }
    }
    perms.insert("allow".to_string(), serde_json::json!(merged));
    true
}

/// Build the temp config root for a Devin child: mirrors the real config
/// root with symlinks, writes a `devin/config.json` that merges the thread
/// allowlist into the user's own. Returns None when the existing config
/// cannot be merged without losing it.
#[cfg(unix)]
async fn write_permission_config(
    real_root: &Path,
    rules: &[String],
) -> anyhow::Result<Option<tempfile::TempDir>> {
    let real_devin = real_root.join("devin");
    let mut config = match tokio::fs::read(real_devin.join("config.json")).await {
        Ok(bytes) => match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "devin config is not plain JSON; thread permissions not applied"
                );
                return Ok(None);
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => serde_json::json!({}),
        Err(e) => return Err(e.into()),
    };
    if !merge_permission_rules(&mut config, rules) {
        tracing::warn!(
            "devin config permissions are not an object; thread permissions not applied"
        );
        return Ok(None);
    }

    let temp = tempfile::tempdir()?;
    let xdg = temp.path();

    if real_root.is_dir() {
        let mut entries = tokio::fs::read_dir(real_root).await?;
        while let Some(entry) = entries.next_entry().await? {
            if entry.file_name() == "devin" {
                continue;
            }
            std::os::unix::fs::symlink(entry.path(), xdg.join(entry.file_name()))?;
        }
    }

    let fake_devin = xdg.join("devin");
    tokio::fs::create_dir_all(&fake_devin).await?;
    if real_devin.is_dir() {
        let mut entries = tokio::fs::read_dir(&real_devin).await?;
        while let Some(entry) = entries.next_entry().await? {
            if entry.file_name() == "config.json" {
                continue;
            }
            std::os::unix::fs::symlink(entry.path(), fake_devin.join(entry.file_name()))?;
        }
    }
    tokio::fs::write(
        fake_devin.join("config.json"),
        serde_json::to_vec_pretty(&config)?,
    )
    .await?;
    Ok(Some(temp))
}

#[cfg(not(unix))]
async fn write_permission_config(
    _real_root: &Path,
    rules: &[String],
) -> anyhow::Result<Option<tempfile::TempDir>> {
    if !rules.is_empty() {
        tracing::warn!(
            "thread permission rules cannot be injected into devin acp on this platform"
        );
    }
    Ok(None)
}

#[async_trait]
impl Provider for AcpProvider {
    fn id(&self) -> &str {
        self.kind.id()
    }

    fn name(&self) -> &str {
        self.kind.name()
    }

    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        match self.fetch_models().await {
            Ok(models) if !models.is_empty() => Ok(models),
            Ok(_) | Err(_) => Ok(models::static_models(self.kind)),
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
            usage: result.usage,
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
            usage: result.usage,
        })
    }

    async fn health_check(&self) -> anyhow::Result<()> {
        self.do_health_check().await
    }

    async fn version_info(&self) -> crate::providers::ProviderVersion {
        self.check_version().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::future::Future;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::pin::Pin;

    fn provider() -> AcpProvider {
        AcpProvider::new(AgentKind::Devin, "devin".into(), "swe-1-7".into())
    }

    /// A minimal ACP agent on stdin/stdout: answers `initialize`,
    /// `session/new` (advertising `model` and `reasoning_effort` select
    /// options), records every `session/set_config_option` request line to
    /// `log_path`, and ends each prompt turn immediately.
    #[cfg(unix)]
    fn fake_acp_agent() -> (tempfile::TempDir, String, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fake-agent");
        let log = dir.path().join("requests.log");
        fs::write(
            &script,
            format!(
                "#!/bin/sh\n\
                 while IFS= read -r line; do\n\
                 \x20 id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\(\"[^\"]*\"\\|[0-9][0-9]*\\).*/\\1/p')\n\
                 \x20 [ -z \"$id\" ] && continue\n\
                 \x20 case \"$line\" in\n\
                 \x20   *'\"session/new\"'*)\n\
                 \x20     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":'$id',\"result\":{{\"sessionId\":\"fake-session\",\"configOptions\":[{{\"id\":\"model\",\"name\":\"Model\",\"type\":\"select\",\"currentValue\":\"grok-4.6\",\"options\":[{{\"value\":\"grok-4.6\",\"name\":\"Grok 4.6\"}}]}},{{\"id\":\"reasoning_effort\",\"name\":\"Reasoning Effort\",\"type\":\"select\",\"currentValue\":\"high\",\"options\":[{{\"value\":\"low\",\"name\":\"Low\"}},{{\"value\":\"medium\",\"name\":\"Medium\"}},{{\"value\":\"high\",\"name\":\"High\"}},{{\"value\":\"xhigh\",\"name\":\"Extra High\"}}]}}]}}}}' ;;\n\
                 \x20   *'\"session/set_config_option\"'*)\n\
                 \x20     printf '%s\\n' \"$line\" >> '{}'\n\
                 \x20     printf '{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{{}}}}\\n' \"$id\" ;;\n\
                 \x20   *'\"session/prompt\"'*)\n\
                 \x20     printf '{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{{\"stopReason\":\"end_turn\"}}}}\\n' \"$id\" ;;\n\
                 \x20   *)\n\
                 \x20     printf '{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{{\"protocolVersion\":1}}}}\\n' \"$id\" ;;\n\
                 \x20 esac\n\
                 done\n",
                log.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        (dir, script.to_string_lossy().to_string(), log)
    }

    fn send_options(working_dir: PathBuf, reasoning_effort: Option<&str>) -> SendOptions {
        SendOptions {
            model: "grok-4.6".into(),
            reasoning_effort: reasoning_effort.map(str::to_string),
            working_dir,
            permission_mode: "normal".into(),
            permissions: None,
            attachments: vec![],
            permission_callback: None,
            ask_callback: None,
            part_callback: None,
            session_callback: None,
            interaction_mode: "code".into(),
            cancel_signal: None,
            max_output_tokens: None,
        }
    }

    /// Parse the recorded `session/set_config_option` request lines into
    /// `(configId, value)` pairs.
    #[cfg(unix)]
    fn logged_config_sets(log: &Path) -> Vec<(String, String)> {
        fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .filter(|v| v["method"] == "session/set_config_option")
            .map(|v| {
                (
                    v["params"]["configId"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                    v["params"]["value"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                )
            })
            .collect()
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn grok_start_sets_model_and_reasoning_effort() {
        let (_dir, bin, log) = fake_acp_agent();
        let provider = AcpProvider::new(AgentKind::Grok, bin, "grok-4.6".into());
        let workdir = tempfile::tempdir().unwrap();

        let res = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            provider.start(StartRequest {
                prompt: "hi".into(),
                options: send_options(workdir.path().to_path_buf(), Some("low")),
            }),
        )
        .await
        .expect("prompt timed out")
        .unwrap();

        assert_eq!(res.session_id, "fake-session");
        let sets = logged_config_sets(&log);
        assert!(
            sets.contains(&("model".into(), "grok-4.6".into())),
            "{sets:?}"
        );
        assert!(
            sets.contains(&("reasoning_effort".into(), "low".into())),
            "{sets:?}"
        );
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn unknown_reasoning_effort_keeps_agent_default() {
        let (_dir, bin, log) = fake_acp_agent();
        let provider = AcpProvider::new(AgentKind::Grok, bin, "grok-4.6".into());
        let workdir = tempfile::tempdir().unwrap();

        tokio::time::timeout(
            std::time::Duration::from_secs(30),
            provider.start(StartRequest {
                prompt: "hi".into(),
                options: send_options(workdir.path().to_path_buf(), Some("bogus")),
            }),
        )
        .await
        .expect("prompt timed out")
        .unwrap();

        let sets = logged_config_sets(&log);
        assert!(
            sets.contains(&("model".into(), "grok-4.6".into())),
            "{sets:?}"
        );
        assert!(
            !sets.iter().any(|(id, _)| id == "reasoning_effort"),
            "{sets:?}"
        );
    }

    /// Fake ACP agent for session/load tests: logs every request line,
    /// reports the `loadSession` capability per `capable`, and answers
    /// `session/load` with either an empty result or a JSON-RPC error.
    #[cfg(unix)]
    fn fake_acp_agent_load(capable: bool, load_ok: bool) -> (tempfile::TempDir, String, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("fake-agent");
        let log = dir.path().join("requests.log");
        let load_result = if load_ok {
            r#""result":{"configOptions":[]}"#
        } else {
            r#""error":{"code":-32602,"message":"unknown session"}"#
        };
        fs::write(
            &script,
            format!(
                "#!/bin/sh\n\
                 while IFS= read -r line; do\n\
                 \x20 id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\(\"[^\"]*\"\\|[0-9][0-9]*\\).*/\\1/p')\n\
                 \x20 [ -z \"$id\" ] && continue\n\
                 \x20 printf '%s\\n' \"$line\" >> '{}'\n\
                 \x20 case \"$line\" in\n\
                 \x20   *'\"initialize\"'*)\n\
                 \x20     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":'$id',\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":{capable}}}}}}}' ;;\n\
                 \x20   *'\"session/load\"'*)\n\
                 \x20     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":'$id',{load_result}}}' ;;\n\
                 \x20   *'\"session/new\"'*)\n\
                 \x20     printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"id\":'$id',\"result\":{{\"sessionId\":\"new-session\",\"configOptions\":[]}}}}' ;;\n\
                 \x20   *'\"session/prompt\"'*)\n\
                 \x20     printf '{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{{\"stopReason\":\"end_turn\"}}}}\\n' \"$id\" ;;\n\
                 \x20   *)\n\
                 \x20     printf '{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{{}}}}\\n' \"$id\" ;;\n\
                 \x20 esac\n\
                 done\n",
                log.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        (dir, script.to_string_lossy().to_string(), log)
    }

    #[cfg(unix)]
    fn logged_methods(log: &Path) -> Vec<String> {
        fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .filter_map(|v| v["method"].as_str().map(str::to_string))
            .collect()
    }

    #[cfg(unix)]
    async fn send_with_stored_session(bin: &str) -> (SendResponse, Arc<Mutex<Vec<String>>>) {
        let provider = AcpProvider::new(AgentKind::Devin, bin.to_string(), "swe-1-7".into());
        let workdir = tempfile::tempdir().unwrap();
        let sessions = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut opts = send_options(workdir.path().to_path_buf(), None);
        let recorded = sessions.clone();
        opts.session_callback = Some(Arc::new(move |sid: String| {
            let recorded = recorded.clone();
            Box::pin(async move { recorded.lock().await.push(sid) })
                as Pin<Box<dyn Future<Output = ()> + Send>>
        }));
        let res = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            provider.send(SendRequest {
                session_id: "stored-session".into(),
                prompt: "hi".into(),
                options: opts,
            }),
        )
        .await
        .expect("send timed out")
        .unwrap();
        (res, sessions)
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn send_without_load_capability_starts_new_session() {
        let (_dir, bin, log) = fake_acp_agent_load(false, true);
        let (_res, sessions) = send_with_stored_session(&bin).await;
        let methods = logged_methods(&log);
        assert!(methods.contains(&"session/new".to_string()), "{methods:?}");
        assert!(
            !methods.contains(&"session/load".to_string()),
            "{methods:?}"
        );
        assert_eq!(*sessions.lock().await, vec!["new-session".to_string()]);
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn send_falls_back_when_session_load_fails() {
        let (_dir, bin, log) = fake_acp_agent_load(true, false);
        let (_res, sessions) = send_with_stored_session(&bin).await;
        let methods = logged_methods(&log);
        assert!(methods.contains(&"session/load".to_string()), "{methods:?}");
        assert!(methods.contains(&"session/new".to_string()), "{methods:?}");
        assert_eq!(*sessions.lock().await, vec!["new-session".to_string()]);
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn send_reuses_session_when_load_succeeds() {
        let (_dir, bin, log) = fake_acp_agent_load(true, true);
        let (_res, sessions) = send_with_stored_session(&bin).await;
        let methods = logged_methods(&log);
        assert!(methods.contains(&"session/load".to_string()), "{methods:?}");
        assert!(!methods.contains(&"session/new".to_string()), "{methods:?}");
        assert!(sessions.lock().await.is_empty());
    }

    #[test]
    fn permission_rules_split_on_commas_and_newlines() {
        assert_eq!(
            parse_permission_rules(Some("Exec(curl), Fetch(**)\nRead(src/**)\r\n,\t")),
            vec!["Exec(curl)", "Fetch(**)", "Read(src/**)"]
        );
        assert!(parse_permission_rules(None).is_empty());
        assert!(parse_permission_rules(Some("  ,\n")).is_empty());
    }

    #[test]
    fn merge_permission_rules_preserves_user_config() {
        let mut config = serde_json::json!({
            "agent": {"model": "x"},
            "permissions": {
                "allow": ["Exec(git status)"],
                "deny": ["Exec(rm)"]
            }
        });
        assert!(merge_permission_rules(
            &mut config,
            &["Exec(curl)".into(), "Exec(git status)".into()]
        ));
        assert_eq!(
            config["permissions"]["allow"],
            serde_json::json!(["Exec(git status)", "Exec(curl)"])
        );
        assert_eq!(
            config["permissions"]["deny"],
            serde_json::json!(["Exec(rm)"])
        );
        assert_eq!(config["agent"]["model"], "x");
    }

    #[test]
    fn merge_permission_rules_rejects_non_object_permissions() {
        let mut config = serde_json::json!({"permissions": "oops"});
        assert!(!merge_permission_rules(&mut config, &["Exec(ls)".into()]));
        assert_eq!(config["permissions"], "oops");
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn permission_config_merges_allowlist_and_mirrors_root() {
        let root = tempfile::tempdir().unwrap();
        let devin = root.path().join("devin");
        fs::create_dir(&devin).unwrap();
        fs::write(
            devin.join("config.json"),
            r#"{"agent":{"model":"x"},"permissions":{"allow":["Exec(git status)"],"deny":["Exec(rm)"]}}"#,
        )
        .unwrap();
        fs::create_dir(devin.join("skills")).unwrap();
        fs::create_dir(root.path().join("otherapp")).unwrap();

        let temp = write_permission_config(root.path(), &["Exec(curl)".into(), "Fetch(**)".into()])
            .await
            .unwrap()
            .unwrap();
        let xdg = temp.path();

        let written: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(xdg.join("devin/config.json")).unwrap())
                .unwrap();
        assert_eq!(written["agent"]["model"], "x");
        assert_eq!(
            written["permissions"]["deny"],
            serde_json::json!(["Exec(rm)"])
        );
        assert_eq!(
            written["permissions"]["allow"],
            serde_json::json!(["Exec(git status)", "Exec(curl)", "Fetch(**)"])
        );

        assert!(xdg
            .join("devin/skills")
            .symlink_metadata()
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(xdg
            .join("otherapp")
            .symlink_metadata()
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!xdg
            .join("devin/config.json")
            .symlink_metadata()
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn permission_config_skips_unmergeable_user_config() {
        let root = tempfile::tempdir().unwrap();
        let devin = root.path().join("devin");
        fs::create_dir(&devin).unwrap();
        fs::write(devin.join("config.json"), b"// jsonc comment").unwrap();
        assert!(write_permission_config(root.path(), &["Exec(ls)".into()])
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn permission_config_env_only_for_devin_with_rules() {
        let mut opts = send_options(std::env::temp_dir(), None);
        let devin = AcpProvider::new(AgentKind::Devin, "devin".into(), "m".into());
        let grok = AcpProvider::new(AgentKind::Grok, "grok".into(), "m".into());

        opts.permissions = None;
        let (env, cfg) = devin.permission_config_env(&opts).await.unwrap();
        assert!(env.is_empty() && cfg.is_none());

        opts.permissions = Some("Exec(ls)".into());
        let (env, cfg) = grok.permission_config_env(&opts).await.unwrap();
        assert!(env.is_empty() && cfg.is_none());

        let (env, cfg) = devin.permission_config_env(&opts).await.unwrap();
        assert_eq!(env.len(), 1);
        assert!(env[0].starts_with("XDG_CONFIG_HOME="));
        assert!(cfg.is_some());
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

        let (blocks, _staged) = provider()
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

        let (blocks, _staged) = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();

        assert_eq!(blocks.len(), 1);
        let ContentBlock::Text(text) = &blocks[0] else {
            panic!("expected text block, got {:?}", blocks[0]);
        };
        assert!(text.text.contains("@"));
        assert!(text.text.contains("secret.txt"));

        let att_dir = root.path().join(".devinorium-attachments");
        let staged_dirs: Vec<_> = fs::read_dir(&att_dir).unwrap().flatten().collect();
        assert_eq!(staged_dirs.len(), 1);
        let entries: Vec<_> = fs::read_dir(staged_dirs[0].path())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(entries.len(), 1);
        let content = fs::read_to_string(entries[0].path()).unwrap();
        assert_eq!(content, "PINEAPPLE");
    }

    #[tokio::test]
    async fn staged_dir_is_removed_when_guard_drops() {
        let root = tempfile::tempdir().unwrap();
        let attachments = vec![Attachment {
            filename: "a.txt".into(),
            mime: "text/plain".into(),
            data: b"x".to_vec(),
        }];
        let (_, staged) = provider()
            .attachment_blocks(&attachments, root.path())
            .await
            .unwrap();
        let parent = root.path().join(".devinorium-attachments");
        assert!(parent.is_dir());
        drop(staged);
        // The turn subdir is removed and the emptied parent goes with it.
        assert!(!parent.exists());
    }

    #[tokio::test]
    async fn empty_attachments_returns_empty_blocks() {
        let (blocks, _) = provider()
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

        let (blocks, _staged) = provider()
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

        let (blocks, _staged) = provider()
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

        assert_ne!(first.text, second.text);

        let att_dir = root.path().join(".devinorium-attachments");
        let staged_dirs: Vec<_> = fs::read_dir(&att_dir).unwrap().flatten().collect();
        assert_eq!(staged_dirs.len(), 1);
        let entries: Vec<_> = fs::read_dir(staged_dirs[0].path())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(entries.len(), 2);
    }
}
