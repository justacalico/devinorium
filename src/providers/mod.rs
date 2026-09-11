//! AI provider abstraction.
//!
//! Devinorium talks to AI backends through a single [`Provider`] trait. The
//! built-in providers drive CLIs through the Agent Client Protocol ([`acp`]):
//! the Devin CLI (`devin acp`), OpenCode (`opencode acp`), and Grok Code
//! (`grok agent stdio`). Adding a new
//! provider is a two-step change:
//!
//! 1. **Create one new file** `src/providers/<name>.rs` implementing [`Provider`]
//!    (or a new [`acp::AgentKind`] variant when the agent speaks ACP).
//! 2. **Edit the registry** below — add a match arm in [`build_provider`]
//!    (and the id to [`available_providers`]).
//!
//! See [`docs/providers.md`] for a walkthrough.

pub mod acp;
pub mod ask;
pub mod codex;
pub mod parts;
pub mod status;
pub mod version;

pub use ask::{AskCallback, AskOption, AskOutcome, AskQuestion, AskRequest, AskResponse};
pub use parts::{
    collect_text, collect_thinking, strip_plan_markup_from_parts, MessagePart, PartCallback,
    PartEvent,
};
pub use status::{ProviderStatus, ProviderStatusCache};
pub use version::ProviderVersion;

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

/// Callback the API layer supplies so the provider can report a session id
/// as soon as a session is created, before the prompt completes.
pub type SessionCallback =
    Arc<dyn Fn(String) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

/// A single file diff streamed from the agent via `ToolCallContent::Diff`.
/// `old_text` is `None` for newly created files.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileDiff {
    pub path: String,
    pub old_text: Option<String>,
    pub new_text: String,
}

/// A tool call streamed from the agent, rendered separately from the reply.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolCallEvent {
    pub id: String,
    pub title: String,
    pub kind: String,
    pub status: String,
    pub command: Option<String>,
    pub output: Option<String>,
    pub output_preview: Option<String>,
    pub changed_files: Vec<String>,
    /// Per-file diffs extracted from `ToolCallContent::Diff` updates. Later
    /// updates for the same path replace earlier ones so the UI always shows
    /// the most recent version of the file content.
    #[serde(default)]
    pub diffs: Vec<FileDiff>,
}

/// Options shared by [`Provider::start`] and [`Provider::send`].
#[derive(Clone)]
pub struct SendOptions {
    // Manual Debug impl below.
    /// The model to use (ignored when resuming an existing session).
    pub model: String,
    /// The reasoning effort the model should run at, when the model exposes
    /// multiple levels. `None` or empty lets the provider use its default.
    pub reasoning_effort: Option<String>,
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
    /// Optional callback that handles form-based ask requests.
    pub ask_callback: Option<AskCallback>,
    /// Optional callback for each ordered message part.
    pub part_callback: Option<PartCallback>,
    /// Optional callback fired as soon as the provider has a session id.
    pub session_callback: Option<SessionCallback>,
    /// Provider interaction mode: "code", "plan", "ask".
    pub interaction_mode: String,
    /// Cancellation flag. When set to true the provider should cancel the
    /// in-flight prompt gracefully (e.g. via ACP `$/cancelRequest`) so the
    /// agent session preserves its context for subsequent messages.
    pub cancel_signal: Option<Arc<std::sync::atomic::AtomicBool>>,
}

impl std::fmt::Debug for SendOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SendOptions")
            .field("model", &self.model)
            .field("reasoning_effort", &self.reasoning_effort)
            .field("working_dir", &self.working_dir)
            .field("permission_mode", &self.permission_mode)
            .field("permissions", &self.permissions)
            .field("attachments", &self.attachments.len())
            .field("permission_callback", &self.permission_callback.is_some())
            .field("ask_callback", &self.ask_callback.is_some())
            .field("part_callback", &self.part_callback.is_some())
            .field("session_callback", &self.session_callback.is_some())
            .field("interaction_mode", &self.interaction_mode)
            .finish()
    }
}

/// Request to start a brand-new conversation.
#[derive(Debug, Clone)]
pub struct StartRequest {
    pub prompt: String,
    pub options: SendOptions,
}

/// Token and cost usage reported by a provider.
///
/// Values are cumulative session totals as reported by the agent (matching
/// ACP `session/prompt` semantics), not per-turn counts. The per-turn delta
/// is computed against the previous snapshot when the turn is recorded.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageSnapshot {
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Reasoning/thinking tokens; a subset of `output_tokens`.
    pub thought_tokens: u64,
    pub cached_read_tokens: u64,
    pub cached_write_tokens: u64,
    pub total_tokens: u64,
    /// Cumulative session cost, when the agent reports it.
    pub cost_amount: Option<f64>,
    /// ISO 4217 currency code for `cost_amount`.
    pub cost_currency: Option<String>,
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
    /// The ordered parts that make up the reply.
    pub parts: Vec<MessagePart>,
    /// A suggested title for the thread (e.g. derived from the first prompt).
    pub title: String,
    /// Cumulative usage snapshot after the first turn, if reported.
    pub usage: Option<UsageSnapshot>,
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
    pub parts: Vec<MessagePart>,
    /// Cumulative usage snapshot after this turn, if reported.
    pub usage: Option<UsageSnapshot>,
}

/// Metadata about a provider the backend knows.
#[derive(Debug, Clone, Serialize)]
pub struct ProviderInfo {
    pub id: &'static str,
    pub name: &'static str,
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
    /// The reasoning effort the provider suggests when the user has not
    /// picked one. `None` means the model does not expose reasoning levels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
    /// The reasoning effort levels this model supports, in the provider's
    /// preferred order. Empty means the model does not expose a picker.
    #[serde(default)]
    pub supported_reasoning_efforts: Vec<String>,
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

    /// Verify the provider is reachable without running a prompt.
    /// For the Devin CLI this opens an ACP session, sends `Initialize`,
    /// and immediately closes.
    async fn health_check(&self) -> anyhow::Result<()>;

    /// Best-effort version info for the provider's backing binary: the
    /// installed version and the latest published version, when the
    /// provider can report them. The default implementation reports
    /// nothing; providers that can check for updates override it.
    async fn version_info(&self) -> ProviderVersion {
        ProviderVersion::default()
    }
}

/// Prepend a mode instruction to the prompt so the agent behaves according to
/// the selected composer mode (plan/ask/code). Providers that cannot set the
/// mode natively rely on this; the markup conventions are devinorium's own.
pub(crate) fn apply_interaction_mode_prefix(prompt: String, mode: &str) -> String {
    match mode.trim().to_lowercase().as_str() {
        "plan" => format!(
            "You are in Plan mode. First produce a concise, decision-complete \
plan and do not run tools, edit files, or execute commands until the user \
confirms. Wrap the final plan in a `<proposed_plan>` block with \
`<step status=\"pending\">...</step>` children. At most one step may be \
`in_progress`.\n\n{prompt}"
        ),
        "ask" => format!(
            "You are in Ask mode. Answer the user's question directly and do \
not use tools, edit files, or execute commands.\n\n{prompt}"
        ),
        _ => format!(
            "{prompt}\n\nWhen working on a multi-step task, you may track \
progress by emitting `<update_plan explanation=\"...\"><step \
status=\"pending|in_progress|completed\">...</step></update_plan>` blocks. \
Only one step should be `in_progress` at a time."
        ),
    }
}

/// Derive a short title from the first non-empty line of a prompt.
pub fn title_from_prompt(prompt: &str) -> String {
    let title = prompt
        .lines()
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or_else(|| prompt.trim());
    if title.is_empty() {
        return "New thread".into();
    }
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
    pub command: String,
    pub default_model: String,
}

/// The list of providers known to the registry.
///
/// **When adding a provider, append its entry here.**
pub fn available_providers() -> Vec<ProviderInfo> {
    vec![
        ProviderInfo {
            id: "devin-cli",
            name: "Devin CLI",
        },
        ProviderInfo {
            id: "opencode",
            name: "OpenCode",
        },
        ProviderInfo {
            id: codex::PROVIDER_ID,
            name: "Codex CLI",
        },
        ProviderInfo {
            id: acp::AgentKind::Grok.id(),
            name: "Grok Code",
        },
    ]
}

/// The binary a provider defaults to when the user has not configured one.
pub fn default_command(provider_id: &str) -> &'static str {
    match provider_id {
        "opencode" => acp::AgentKind::Opencode.default_command(),
        codex::PROVIDER_ID => "codex",
        "grok" => acp::AgentKind::Grok.default_command(),
        _ => acp::AgentKind::Devin.default_command(),
    }
}

/// Find a registered provider by id.
pub fn provider_name(id: &str) -> Option<&'static str> {
    available_providers()
        .into_iter()
        .find(|p| p.id == id)
        .map(|p| p.name)
}

/// Construct a provider by id.
///
/// **When adding a provider, add one match arm here.**
pub fn build_provider(cfg: ProviderConfig) -> anyhow::Result<Box<dyn Provider>> {
    if cfg.id == codex::PROVIDER_ID {
        return Ok(Box::new(codex::CodexProvider::new(
            cfg.command,
            cfg.default_model,
        )));
    }
    let kind = match cfg.id.as_str() {
        "devin-cli" => acp::AgentKind::Devin,
        "opencode" => acp::AgentKind::Opencode,
        "grok" => acp::AgentKind::Grok,
        other => anyhow::bail!("unknown provider: {other}"),
    };
    Ok(Box::new(acp::AcpProvider::new(
        kind,
        cfg.command.clone(),
        cfg.default_model.clone(),
    )))
}

#[cfg(test)]
mod tests {
    use super::title_from_prompt;

    #[test]
    fn title_from_prompt_uses_first_line() {
        assert_eq!(title_from_prompt("Hello world"), "Hello world");
    }

    #[test]
    fn title_from_prompt_skips_leading_blank_lines() {
        assert_eq!(title_from_prompt("\n\nHello"), "Hello");
    }

    #[test]
    fn title_from_prompt_truncates_long_first_lines() {
        let prompt = "a".repeat(100);
        let title = title_from_prompt(&prompt);
        assert_eq!(title.len(), 80, "expected 77 chars + '...'");
        assert!(title.ends_with("..."));
    }

    #[test]
    fn title_from_prompt_falls_back_for_whitespace_only() {
        assert_eq!(title_from_prompt("   \n   \n"), "New thread");
    }
}
