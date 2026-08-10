//! AI provider abstraction.
//!
//! Devinorium talks to AI backends through a single [`Provider`] trait. Today
//! the only implementation is the `devin` CLI ([`devin_cli`]), but the design
//! makes adding a new provider a two-step change:
//!
//! 1. **Create one new file** `src/providers/<name>.rs` implementing [`Provider`].
//! 2. **Edit one line** in the registry below — add a match arm in
//!    [`build_provider`] (and the id to [`available_providers`]).
//!
//! That's it. No other file needs to change.
//!
//! See [`docs/providers.md`] for a walkthrough.

pub mod devin_cli;

use std::path::{Path, PathBuf};

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

/// Options shared by [`Provider::start`] and [`Provider::send`].
#[derive(Debug, Clone)]
pub struct SendOptions {
    /// The model to use (ignored when resuming an existing session).
    pub model: String,
    /// Working directory the provider should operate in.
    pub working_dir: PathBuf,
    /// Permission mode: "normal", "accept-edits", "smart", "bypass".
    pub permission_mode: String,
    /// Attachments to include with the message.
    pub attachments: Vec<Attachment>,
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
}

/// Metadata about a model the provider offers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
    pub cost_tier: String,
    pub family: String,
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
    async fn export(&self, session_id: &str, working_dir: &Path) -> anyhow::Result<serde_json::Value>;
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
        "devin-cli" => Ok(Box::new(devin_cli::DevinCliProvider::new(
            cfg.devin_bin.clone(),
            cfg.default_model.clone(),
        ))),
        other => anyhow::bail!("unknown provider: {other}"),
    }
}
