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

use agent_client_protocol::{
    schema::v1::{
        ClientCapabilities, ContentBlock, CreateElicitationRequest, CreateElicitationResponse,
        ElicitationAction, ElicitationCapabilities, ElicitationFormCapabilities, ImageContent,
        InitializeRequest, LoadSessionRequest, LoadSessionResponse, NewSessionRequest,
        NewSessionResponse, PromptRequest, RequestPermissionOutcome, RequestPermissionRequest,
        RequestPermissionResponse, SessionId, SessionNotification, SetSessionModeRequest,
        TextContent,
    },
    schema::ProtocolVersion as ProtocolVersionEnum,
    AcpAgent, Agent, Client, ConnectionTo,
};

use super::{
    content::sanitize, elicitation::handle_ask_request, models::static_models,
    permissions::handle_permission_request, session_config::apply_session_config,
    tool_calls::apply_notification,
};
use crate::providers::{
    collect_text, collect_thinking, title_from_prompt, Attachment, MessagePart, ModelInfo,
    PartCallback, Provider, SendOptions, SendRequest, SendResponse, StartRequest, StartResponse,
};

pub const PROVIDER_ID: &str = "devin-cli";
pub const PROVIDER_NAME: &str = "Devin CLI";

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
        let path = tokio::task::spawn_blocking({
            let bin = self.bin.clone();
            move || which::which(&bin)
        })
        .await?;

        if path.is_err() {
            anyhow::bail!("provider command not found: {}", self.bin);
        }

        let health = Client.builder().name("devinorium").connect_with(
            AcpAgent::from_args([&self.bin, "acp"])?,
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
}

async fn cancel_wait(flag: Arc<AtomicBool>) {
    while !flag.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
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
        let ask_callback = options.ask_callback.clone();
        let cancel_signal = options.cancel_signal.clone();
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
                AcpAgent::from_args([&self.bin, "acp"])?,
                async move |connection: ConnectionTo<Agent>| {
                    let _init_response = connection
                        .send_request(
                            InitializeRequest::new(ProtocolVersionEnum::V1)
                                .client_capabilities(client_capabilities()),
                        )
                        .block_task()
                        .await?;

                    let (session_id, config_options) = if let Some(ref sid) = maybe_session {
                        let load_resp: LoadSessionResponse = connection
                            .send_request(LoadSessionRequest::new(
                                SessionId::new(sid.clone()),
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

                    if maybe_session.is_none() {
                        if let Some(ref cb) = options.session_callback {
                            cb(session_id.clone()).await;
                        }
                    }

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

fn client_capabilities() -> ClientCapabilities {
    ClientCapabilities::new()
        .elicitation(ElicitationCapabilities::new().form(ElicitationFormCapabilities::new()))
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

        assert_ne!(first.text, second.text);

        let att_dir = root.path().join(".devinorium-attachments");
        let entries: Vec<_> = fs::read_dir(&att_dir).unwrap().flatten().collect();
        assert_eq!(entries.len(), 2);
    }
}
