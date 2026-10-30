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
    /// `grok agent stdio` — the Grok Code CLI.
    Grok,
    /// `gemini --experimental-acp`: the Gemini CLI.
    Gemini,
}

impl AgentKind {
    /// Provider id used in the registry, user settings, and thread rows.
    pub fn id(self) -> &'static str {
        match self {
            Self::Devin => "devin-cli",
            Self::Opencode => "opencode",
            Self::Grok => "grok",
            Self::Gemini => "gemini",
        }
    }

    /// Human-readable provider name.
    pub fn name(self) -> &'static str {
        match self {
            Self::Devin => "Devin CLI",
            Self::Opencode => "OpenCode",
            Self::Grok => "Grok Code",
            Self::Gemini => "Gemini CLI",
        }
    }

    /// The command used when the user has not configured one.
    pub fn default_command(self) -> &'static str {
        match self {
            Self::Devin => "devin",
            Self::Opencode => "opencode",
            Self::Grok => "grok",
            Self::Gemini => "gemini",
        }
    }

    /// Arguments after the binary that start the ACP stdio server.
    pub fn acp_args(self) -> &'static [&'static str] {
        match self {
            Self::Devin | Self::Opencode => &["acp"],
            Self::Grok => &["agent", "stdio"],
            Self::Gemini => &["--experimental-acp"],
        }
    }

    /// CLI args appended after [`acp_args`](Self::acp_args) when the agent is
    /// spawned for a prompt turn. Gemini advertises no `model` session
    /// config option over ACP, so the requested model goes on the command
    /// line instead. The value is constrained to model-id characters and
    /// may not start with `-`, so a stored thread model can never turn
    /// into a different flag.
    pub fn extra_spawn_args(self, model: &str) -> Vec<String> {
        match self {
            Self::Gemini => {
                let model = model.trim();
                let safe = !model.is_empty()
                    && !model.starts_with('-')
                    && model
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'));
                if safe {
                    vec!["--model".into(), model.to_string()]
                } else {
                    if !model.is_empty() {
                        tracing::warn!(
                            model = %model,
                            "gemini model id is not flag-safe; running the CLI default"
                        );
                    }
                    Vec::new()
                }
            }
            _ => Vec::new(),
        }
    }

    /// JSON manifest URL whose top-level `version` field names the latest
    /// published release. Grok has no manifest; its update check goes
    /// through `<bin> update --check --json` instead.
    pub fn version_manifest_url(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("https://static.devin.ai/cli/current/manifest.json"),
            Self::Opencode => Some("https://registry.npmjs.org/opencode-ai/latest"),
            Self::Grok => None,
            Self::Gemini => Some("https://registry.npmjs.org/@google%2Fgemini-cli/latest"),
        }
    }

    /// Session config option id that carries the composer interaction mode
    /// (code/plan/ask), when the agent exposes one.
    ///
    /// Devin has a dedicated `interaction_mode` option. OpenCode's `mode`
    /// option selects its agent (`build`/`plan`), which is the same idea.
    /// Grok advertises no such option; the prompt prefix carries the mode.
    /// Gemini's modes are its approval modes, so the interaction mode is
    /// carried by `session/set_mode` plus the prompt prefix.
    pub fn interaction_mode_option(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("interaction_mode"),
            Self::Opencode => Some("mode"),
            Self::Grok | Self::Gemini => None,
        }
    }

    /// Session config option id that carries the permission mode
    /// (normal/accept-edits/smart/bypass), when the agent exposes one.
    ///
    /// OpenCode does not publish a permission config option over ACP; its own
    /// permission config decides when `session/request_permission` fires, and
    /// the callback/bypass handling in `permissions.rs` covers the rest.
    /// Grok exposes no permission config option either; its own permission
    /// rules and `session/request_permission` decide when approval is asked.
    /// Gemini maps its approval modes onto `session/set_mode` instead.
    pub fn permission_mode_option(self) -> Option<&'static str> {
        match self {
            Self::Devin => Some("mode"),
            Self::Opencode | Self::Grok | Self::Gemini => None,
        }
    }

    /// Map a composer interaction mode plus permission mode to an ACP
    /// `session/set_mode` id, when the agent supports that request.
    /// OpenCode exposes its agent selection as the `mode` config option
    /// instead, and Grok has no session modes.
    ///
    /// Gemini's session modes are its approval modes (`default`,
    /// `autoEdit`, `yolo`, `plan`), so the permission mode drives the
    /// mapping; an interaction mode of `plan` selects the read-only plan
    /// mode outright. `ask` keeps the permission-derived mode; the prompt
    /// prefix is what enforces "no tools".
    pub fn session_mode_id(
        self,
        interaction_mode: &str,
        permission_mode: &str,
    ) -> Option<SessionModeId> {
        match self {
            Self::Devin => {
                let id = match interaction_mode.trim().to_lowercase().as_str() {
                    "ask" => "ask",
                    "plan" => "plan",
                    _ => "default",
                };
                Some(SessionModeId::new(id))
            }
            Self::Gemini => {
                let id = if interaction_mode.trim().eq_ignore_ascii_case("plan") {
                    "plan"
                } else {
                    match permission_mode.trim() {
                        "bypass" | "yolo" => "yolo",
                        "accept-edits" | "smart" => "autoEdit",
                        _ => "default",
                    }
                };
                Some(SessionModeId::new(id))
            }
            Self::Opencode | Self::Grok => None,
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
            // Grok and Gemini advertise no interaction mode option, so this
            // is only reachable if a future version adds one; take the default.
            Self::Grok | Self::Gemini => choices.first().cloned(),
        }
    }
}
