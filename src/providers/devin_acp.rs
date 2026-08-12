//! Devin CLI ACP (Agent Client Protocol) provider.
//!
//! Spawns `devin acp` and communicates over JSON-RPC stdio using the
//! `agent-client-protocol` crate. Permission requests can be forwarded to the
//! API layer through the optional [`SendOptions::permission_callback`]; if no
//! callback is configured, they are auto-approved with the safest `AllowOnce`
//! option.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};

use super::{
    title_from_prompt, Attachment, ModelInfo, PermissionCallback, PermissionOption,
    PermissionOutcome, PermissionRequest, Provider, SendOptions, SendRequest, SendResponse,
    StartRequest, StartResponse,
};
use agent_client_protocol::{
    schema::ProtocolVersion,
    schema::v1::{
        ContentBlock, EmbeddedResourceResource, InitializeRequest, LoadSessionRequest,
        NewSessionRequest, PermissionOption as AcpPermissionOption, PermissionOptionKind,
        PromptRequest, RequestPermissionOutcome, RequestPermissionRequest,
        RequestPermissionResponse, SelectedPermissionOutcome, SessionNotification, TextContent,
        ToolCallContent,
    },
    AcpAgent, Agent, Client, ConnectionTo,
};

const PROVIDER_ID: &str = "devin-cli";
const PROVIDER_NAME: &str = "Devin CLI";

pub struct DevinAcpProvider {
    bin: String,
    #[allow(dead_code)]
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
    ) -> anyhow::Result<(String, String)> {
        let prompt = self
            .with_attachments(prompt, &options.attachments, &options.working_dir)
            .await?;

        let (text_tx, mut text_rx) = mpsc::unbounded_channel::<String>();
        let text_tx = Arc::new(Mutex::new(Some(text_tx)));

        let cwd = options.working_dir.clone();
        let maybe_session = maybe_session.map(|s| s.to_string());
        let permission_callback = options.permission_callback.clone();

        let result = Client
            .builder()
            .name("devinorium")
            .on_receive_notification(
                {
                    let text_tx = text_tx.clone();
                    async move |notification: SessionNotification, _cx| {
                        extract_text_from_notification(&notification, &text_tx).await;
                        Ok(())
                    }
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                {
                    let permission_callback = permission_callback.clone();
                    async move |request: RequestPermissionRequest, responder, _cx| {
                        let outcome = handle_permission_request(request, permission_callback.as_ref()).await;
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

                    let (session_id, _modes) = if let Some(ref sid) = maybe_session {
                        let _load_response = connection
                            .send_request(LoadSessionRequest::new(
                                agent_client_protocol::schema::v1::SessionId::new(sid.clone()),
                                cwd.clone(),
                            ))
                            .block_task()
                            .await?;
                        (sid.clone(), None)
                    } else {
                        let resp = connection
                            .send_request(NewSessionRequest::new(cwd.clone()))
                            .block_task()
                            .await?;
                        (resp.session_id.to_string(), resp.modes)
                    };

                    let prompt_blocks = vec![ContentBlock::Text(TextContent::new(prompt))];

                    let _prompt_response = connection
                        .send_request(PromptRequest::new(session_id.clone(), prompt_blocks))
                        .block_task()
                        .await?;

                    // Collect any text that arrived while we were waiting.
                    let mut reply = String::new();
                    let _tx = text_tx.lock().await.take();
                    while let Ok(text) = text_rx.try_recv() {
                        reply.push_str(&text);
                    }

                    Ok::<_, agent_client_protocol::Error>((session_id, reply))
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
            anyhow::bail!("devin models list failed: {}", String::from_utf8_lossy(&output.stderr));
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

async fn handle_permission_request(
    request: RequestPermissionRequest,
    permission_callback: Option<&PermissionCallback>,
) -> RequestPermissionOutcome {
    if let Some(callback) = permission_callback {
        let permission_request = map_permission_request(&request);
        match callback(permission_request).await {
            PermissionOutcome::Allow { option_id } => RequestPermissionOutcome::Selected(
                SelectedPermissionOutcome::new(option_id),
            ),
            PermissionOutcome::Cancel => RequestPermissionOutcome::Cancelled,
        }
    } else {
        // No interactive handler: auto-approve using the safest available option.
        request
            .options
            .iter()
            .find(|o| matches!(o.kind, PermissionOptionKind::AllowOnce))
            .or_else(|| request.options.first())
            .map(|o| RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(o.option_id.clone())))
            .unwrap_or(RequestPermissionOutcome::Cancelled)
    }
}

fn map_permission_request(request: &RequestPermissionRequest) -> PermissionRequest {
    let request_id = uuid::Uuid::new_v4().to_string();
    let scope = format!("{}", request.tool_call.tool_call_id);
    let options = request
        .options
        .iter()
        .map(map_permission_option)
        .collect();
    PermissionRequest {
        request_id,
        scope,
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
    text_tx: &Arc<Mutex<Option<mpsc::UnboundedSender<String>>>>,
) {
    use agent_client_protocol::schema::v1::SessionUpdate;
    let text = match &notification.update {
        SessionUpdate::AgentMessageChunk(chunk) => match &chunk.content {
            ContentBlock::Text(t) => Some(t.text.clone()),
            _ => None,
        },
        SessionUpdate::ToolCall(tool_call) => tool_call
            .content
            .iter()
            .filter_map(|c| match c {
                ToolCallContent::Content(content) => text_from_content_block(&content.content),
                _ => None,
            })
            .next(),
        SessionUpdate::ToolCallUpdate(update) => update
            .fields
            .content
            .as_ref()
            .and_then(|contents| {
                contents
                    .iter()
                    .filter_map(|c| match c {
                        ToolCallContent::Content(content) => {
                            text_from_content_block(&content.content)
                        }
                        _ => None,
                    })
                    .next()
            }),
        _ => None,
    };

    if let Some(text) = text {
        let guard = text_tx.lock().await;
        if let Some(tx) = guard.as_ref() {
            let _ = tx.send(text);
        }
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
        let (session_id, reply) = self
            .run_prompt(&req.options, None, req.prompt)
            .await?;

        Ok(StartResponse {
            session_id,
            title,
            reply,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let (_, reply) = self
            .run_prompt(&req.options, Some(&req.session_id), req.prompt)
            .await?;

        Ok(SendResponse { reply })
    }

    async fn export(
        &self,
        _session_id: &str,
        _working_dir: &Path,
    ) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
}
