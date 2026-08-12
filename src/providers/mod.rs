//! AI provider abstraction.
//!
//! Devinorium talks to AI backends through a single [`Provider`] trait. The
//! current implementation drives the `devin` CLI through the Agent Client
//! Protocol ([`devin_acp`]). Adding a new provider is a two-step change:
//!
//! 1. **Create one new file** `src/providers/<name>.rs` implementing [`Provider`].
//! 2. **Edit one line** in the registry below — add a match arm in
//!    [`build_provider`] (and the id to [`available_providers`]).
//!
//! That's it. No other file needs to change.
//!
//! See [`docs/providers.md`] for a walkthrough.

pub mod devin_acp;

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// A single attachment on a user message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Attachment {
    /// Original filename, e.g. "screenshot.png".
    pub filename: String,
    /// MIME type, e.g. "image/png".
    pub mime: String,
    /// Raw bytes of the attachment.
    #[serde(skip)]
    pub data: Vec<u8>,
}

/// A single option presented for an interactive permission request.
#[derive(Debug, Clone, Serialize)]
pub struct PermissionOption {
    pub id: String,
    pub kind: String,
    pub label: Option<String>,
}

/// An interactive permission request that the provider wants the user to
/// decide on (allow/skip/etc.).
#[derive(Debug, Clone, Serialize)]
pub struct PermissionRequest {
    pub request_id: String,
    pub scope: String,
    pub title: String,
    pub input: Option<String>,
    pub options: Vec<PermissionOption>,
}

/// The user's decision for a permission request.
#[derive(Debug, Clone)]
pub enum PermissionOutcome {
    Allow { option_id: String },
    Cancel,
}

/// Callback the API layer supplies to the provider so permission requests
/// can be forwarded to the client (e.g. over SSE) and awaited.
pub type PermissionCallback = Arc<
    dyn Fn(PermissionRequest) -> Pin<Box<dyn Future<Output = PermissionOutcome> + Send>>
        + Send
        + Sync,
>;

pub type StreamChunkCallback = Arc<dyn Fn(String) + Send + Sync + 'static>;

/// A tool call streamed from the agent, rendered separately from the reply.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallEvent {
    pub id: String,
    pub title: String,
    pub kind: String,
    pub status: String,
    pub command: Option<String>,
    pub output: Option<String>,
    pub output_preview: Option<String>,
    pub changed_files: Vec<String>,
}

pub type ToolCallCallback = Arc<dyn Fn(ToolCallEvent) + Send + Sync + 'static>;

/// Options shared by [`Provider::start`] and [`Provider::send`].
#[derive(Clone)]
pub struct SendOptions {
    // Manual Debug impl below.
    /// The model to use (ignored when resuming an existing session).
    pub model: String,
    /// Working directory the provider should operate in.
    pub working_dir: PathBuf,
    /// Permission mode: "normal", "accept-edits", "smart", "bypass".
    pub permission_mode: String,
    /// Optional comma/newline-separated list of permission scopes allowed
    /// for this thread (e.g. "Exec(curl), Fetch(**)").
    pub permissions: Option<String>,
    /// Attachments to include with the message.
    pub attachments: Vec<Attachment>,
    /// Optional callback that handles interactive permission requests.
    pub permission_callback: Option<PermissionCallback>,
    /// Optional callback for each chunk of the assistant's reply.
    pub text_callback: Option<StreamChunkCallback>,
    /// Optional callback for each chunk of the assistant's thinking/reasoning.
    pub thinking_callback: Option<StreamChunkCallback>,
    /// Optional callback for tool call progress updates.
    pub tool_callback: Option<ToolCallCallback>,
}

impl std::fmt::Debug for SendOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendOptions")
            .field("model", &self.model)
            .field("working_dir", &self.working_dir)
            .field("permission_mode", &self.permission_mode)
            .field("permissions", &self.permissions)
            .field("attachments", &self.attachments.len())
            .field("permission_callback", &self.permission_callback.is_some())
            .field("text_callback", &self.text_callback.is_some())
            .field("thinking_callback", &self.thinking_callback.is_some())
            .field("tool_callback", &self.tool_callback.is_some())
            .finish()
    }
}

/// Request to start a brand-new conversation.
#[derive(Debug, Clone)]
pub struct StartRequest {
    pub prompt: String,
    pub options: SendOptions,
}

/// Response from starting a conversation.
#[derive(Debug, Clone, Serialize)]
pub struct StartResponse {
    /// Provider-specific session id used to continue the conversation.
    pub session_id: String,
    /// The assistant's reply text.
    pub reply: String,
    /// The assistant's internal reasoning / thinking, if any.
    pub thinking: String,
    /// A suggested title for the thread (e.g. derived from the first prompt).
    pub title: String,
}

/// Request to continue an existing conversation.
#[derive(Debug, Clone)]
pub struct SendRequest {
    /// The session id returned by [`Provider::start`].
    pub session_id: String,
    pub prompt: String,
    pub options: SendOptions,
}

/// Response from continuing a conversation.
#[derive(Debug, Clone, Serialize)]
pub struct SendResponse {
    pub reply: String,
    pub thinking: String,
}

/// Metadata about a model the provider offers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
    pub cost_tier: String,
    pub family: String,
    pub cost_summary: String,
    pub max_context_tokens: u64,
    pub max_output_tokens: u64,
    pub is_new: bool,
    pub is_beta: bool,
}

/// The trait every AI backend implements.
#[async_trait]
pub trait Provider: Send + Sync {
    /// Stable provider id, e.g. "devin-cli".
    fn id(&self) -> &str;

    /// Human-readable name.
    fn name(&self) -> &str;

    /// List the models this provider can serve.
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>>;

    /// Start a new conversation and return the session id + first reply.
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse>;

    /// Continue an existing conversation by session id.
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse>;

    /// Best-effort: export the full conversation for a session as JSON.
    /// Providers that cannot export should return an empty object.
    async fn export(
        &self,
        session_id: &str,
        working_dir: &Path,
    ) -> anyhow::Result<serde_json::Value>;
}

/// Derive a short title from the first line of a prompt.
pub fn title_from_prompt(prompt: &str) -> String {
    let line = prompt.lines().next().unwrap_or(prompt);
    let title = line.trim();
    let mut chars = title.chars();
    let truncated: String = chars.by_ref().take(77).collect();
    if chars.next().is_some() {
        format!("{truncated}...")
    } else {
        truncated
    }
}

/// Configuration passed to [`build_provider`].
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    pub id: String,
    pub devin_bin: String,
    pub default_model: String,
}

/// The list of provider ids known to the registry.
///
/// **When adding a provider, append its id here.**
pub fn available_providers() -> Vec<&'static str> {
    vec!["devin-cli"]
}

/// Construct a provider by id.
///
/// **When adding a provider, add one match arm here.** This is the single
/// line you edit in this file.
pub fn build_provider(cfg: ProviderConfig) -> anyhow::Result<Box<dyn Provider>> {
    match cfg.id.as_str() {
        "devin-cli" => Ok(Box::new(devin_acp::DevinAcpProvider::new(
            cfg.devin_bin.clone(),
            cfg.default_model.clone(),
        ))),
        other => anyhow::bail!("unknown provider: {other}"),
    }
}
