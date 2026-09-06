//! Per-agent differences for ACP-based providers.
//!
//! Every supported agent speaks the same Agent Client Protocol over stdio
//! (`<bin> acp`), but they differ in which session config options they expose
//! and how modes map onto them. Those differences are small enough to live on
//! one enum instead of a trait.

use agent_client_protocol::schema::v1::SessionModeId;

/// An agent that can be driven over ACP.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentKind {
    /// `devin acp` — the Devin CLI.
    Devin,
    /// `opencode acp` — the OpenCode CLI.
    Opencode,
}

impl AgentKind {
    /// Provider id used in the registry, user settings, and thread rows.
    pub fn id(self) -> &'static str {
        match self {
            Self::Devin => "devin-cli",
            Self::Opencode => "opencode",
        }
    }

    /// Human-readable provider name.
    pub fn name(self) -> &'static str {
        match self {
            Self::Devin => "Devin CLI",
            Self::Opencode => "OpenCode",
        }
    }

    /// The command used when the user has not configured one.
    pub fn default_command(self) -> &'static str {
        match self {
            Self::Devin => "devin",
            Self::Opencode => "opencode",
        }
    }

    /// JSON manifest URL whose top-level `version` field names the latest
    /// published release.
    pub fn version_manifest_url(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("https://static.devin.ai/cli/current/manifest.json"),
            Self::Opencode => Some("https://registry.npmjs.org/opencode-ai/latest"),
        }
    }

    /// Session config option id that carries the composer interaction mode
    /// (code/plan/ask), when the agent exposes one.
    ///
    /// Devin has a dedicated `interaction_mode` option. OpenCode's `mode`
    /// option selects its agent (`build`/`plan`), which is the same idea.
    pub fn interaction_mode_option(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("interaction_mode"),
            Self::Opencode => Some("mode"),
        }
    }

    /// Session config option id that carries the permission mode
    /// (normal/accept-edits/smart/bypass), when the agent exposes one.
    ///
    /// OpenCode does not publish a permission config option over ACP; its own
    /// permission config decides when `session/request_permission` fires, and
    /// the callback/bypass handling in `permissions.rs` covers the rest.
    pub fn permission_mode_option(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("mode"),
            Self::Opencode => None,
        }
    }

    /// Map a composer interaction mode to an ACP `session/set_mode` id, when
    /// the agent supports that request. OpenCode exposes its agent selection
    /// as the `mode` config option instead.
    pub fn session_mode_id(self, mode: &str) -> Option<SessionModeId> {
        match self {
            Self::Devin => {
                let id = match mode.trim().to_lowercase().as_str() {
                    "ask" => "ask",
                    "plan" => "plan",
                    _ => "default",
                };
                Some(SessionModeId::new(id))
            }
            Self::Opencode => None,
        }
    }

    /// Map a requested interaction mode onto one of the agent's advertised
    /// choices for [`interaction_mode_option`](Self::interaction_mode_option).
    /// Returns `None` when nothing fits; the caller then falls back to the
    /// first advertised choice.
    pub fn interaction_mode_value(self, requested: &str, choices: &[String]) -> Option<String> {
        let requested = requested.trim();
        if choices.iter().any(|v| v == requested) {
            return Some(requested.to_string());
        }
        match self {
            Self::Devin => {
                if requested == "code" {
                    choices
                        .iter()
                        .find(|v| *v == "default" || *v == "build")
                        .cloned()
                } else {
                    None
                }
            }
            // `plan` maps to the plan agent; everything else (code, ask, and
            // unknown values) maps to the default build agent. `ask` is
            // additionally enforced through the prompt prefix.
            Self::Opencode => choices
                .iter()
                .find(|v| *v == "build")
                .cloned()
                .or_else(|| choices.first().cloned()),
        }
    }
}
