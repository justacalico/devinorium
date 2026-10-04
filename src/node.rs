//! Wire protocol between a hub and a paired satellite node.
//!
//! A satellite is a stateless agent runner: it has no database, no accounts
//! and no UI. The hub pairs with it once (URL + pairing code), receives a
//! node token, and from then on talks to it over the small `/api/node/*`
//! surface defined here: provider runs, file and git operations, terminals
//! and clones.
//!
//! These types are the contract both sides share. Anything that crosses
//! the wire lives in this module so hub and satellite cannot drift apart.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::mcp::McpServerConfig;
use crate::providers::{AskRequest, MessagePart, PermissionRequest, UsageSnapshot};

/// Prefix every node endpoint lives under.
pub const NODE_API_PREFIX: &str = "/api/node";

/// `GET /api/node/info` response. Unauthenticated: it only exposes the
/// node's display name, id and version, which a hub needs anyway to decide
/// it is talking to a satellite before sending the pairing code.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeInfo {
    pub satellite: bool,
    pub node_id: String,
    pub name: String,
    pub version: String,
}

/// `POST /api/node/pair` request. `code` is the code the satellite printed
/// at startup; `name` lets the hub suggest nothing — the satellite keeps
/// its own configured name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairRequest {
    pub code: String,
}

/// `POST /api/node/pair` response. `token` is the bearer credential the hub
/// sends on every subsequent node call; it never appears in responses
/// again.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairResponse {
    pub node_id: String,
    pub name: String,
    pub version: String,
    pub token: String,
}

/// Provider identity and command the satellite should run for a request.
/// The command is the hub user's configured binary; it is resolved on the
/// satellite's PATH/home, which is the point of running remotely.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireProvider {
    pub id: String,
    pub command: String,
    pub default_model: String,
}

/// Attachment bytes are base64 on the wire; the provider-facing
/// `Attachment` type skips serialization of `data` for DB use.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireAttachment {
    pub filename: String,
    pub mime: String,
    pub data_b64: String,
}

/// The serializable subset of [`crate::providers::SendOptions`]. Callbacks
/// are re-attached on each side rather than serialized.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireSendOptions {
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    pub working_dir: PathBuf,
    pub permission_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permissions: Option<String>,
    #[serde(default)]
    pub attachments: Vec<WireAttachment>,
    pub interaction_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
    #[serde(default)]
    pub mcp_servers: Vec<McpServerConfig>,
    /// When true the satellite expands a leading `/skill` prompt against
    /// its own filesystem before invoking the provider (mirroring what the
    /// hub does locally for non-Devin providers).
    #[serde(default)]
    pub expand_skills: bool,
}

/// `POST /api/node/run` request. `session_id` present means "continue the
/// conversation" (Provider::send); absent means "new conversation"
/// (Provider::start).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunRequest {
    /// Hub-generated id used by `/api/node/runs/:id/cancel`.
    pub run_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub prompt: String,
    pub provider: WireProvider,
    pub options: WireSendOptions,
}

/// Final result of a provider turn, carried by the `done` event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunOutcome {
    /// Set when the provider created (or re-keyed) a session this turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub reply: String,
    pub thinking: String,
    pub parts: Vec<MessagePart>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<UsageSnapshot>,
}

/// Events the satellite streams back during a run, as SSE `event:` names
/// with this enum serialized as the `data:` payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NodeEvent {
    /// The provider session id, emitted as soon as it is known.
    Session { session_id: String },
    /// A streamed message part. `update` marks a tool-call refresh.
    Part { part: MessagePart, update: bool },
    /// The provider wants a permission decision. The hub answers through
    /// `POST /api/node/callback` with the matching `request_id`.
    Permission {
        request_id: String,
        request: PermissionRequest,
    },
    /// A form-based ask request; answered through the same callback route.
    Ask {
        request_id: String,
        request: AskRequest,
    },
    /// The turn finished successfully.
    Done { outcome: Box<RunOutcome> },
    /// The turn failed; the stream ends after this event.
    Error { message: String },
}

/// How the hub answers a pending permission or ask request.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CallbackOutcome {
    Permission {
        option_id: String,
    },
    PermissionCancel,
    Ask {
        answers: HashMap<String, serde_json::Value>,
    },
    AskCancel,
}

/// `POST /api/node/callback` request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallbackRequest {
    pub request_id: String,
    pub outcome: CallbackOutcome,
}

/// `POST /api/node/provider/models` / `health` request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderOpRequest {
    pub id: String,
    pub command: String,
    pub default_model: String,
}

/// `POST /api/node/files/stat` request. `root` scopes relative paths;
/// absolute entries ignore it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
    pub paths: Vec<String>,
}

/// One stat result. `canonical` is the resolved absolute path when the
/// entry exists.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatOut {
    pub exists: bool,
    pub is_dir: bool,
    pub is_symlink: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canonical: Option<String>,
    #[serde(default)]
    pub size: u64,
    /// Unix mtime seconds, when the entry exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatResponse {
    /// Keyed by the requested path string.
    pub results: HashMap<String, StatOut>,
}

/// Error body every node endpoint returns. `kind` lets the hub map git
/// errors back onto [`crate::git::GitError`] without string matching.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeError {
    pub kind: String,
    pub message: String,
}

impl NodeError {
    pub fn new(kind: &str, message: impl Into<String>) -> Self {
        Self {
            kind: kind.to_string(),
            message: message.into(),
        }
    }
}

/// `POST /api/node/terminal/sessions` request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateNodeTerminal {
    pub cwd: PathBuf,
    #[serde(default)]
    pub thread_id: String,
}

/// `POST /api/node/clone` request/response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloneNodeRequest {
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloneNodeResponse {
    pub path: String,
}

/// `POST /api/node/skills/list` request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillListRequest {
    pub working_dir: PathBuf,
}

/// Pairing code alphabet: unambiguous characters only (no 0/O, 1/I/L).
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/// Generate a `XXXX-XXXX-XXXX` pairing code (~60 bits of entropy).
pub fn generate_pairing_code() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let mut out = String::with_capacity(14);
    for i in 0..12 {
        if i > 0 && i % 4 == 0 {
            out.push('-');
        }
        out.push(CODE_ALPHABET[rng.gen_range(0..CODE_ALPHABET.len())] as char);
    }
    out
}

/// Normalize a typed pairing code (uppercase, strip separators/spaces) for
/// comparison.
pub fn normalize_pairing_code(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

/// Whether a typed code matches the issued one. Constant-time on the
/// normalized forms.
pub fn pairing_code_matches(issued: &str, typed: &str) -> bool {
    let a = normalize_pairing_code(issued);
    let b = normalize_pairing_code(typed);
    !b.is_empty() && constant_time_eq::constant_time_eq(a.as_bytes(), b.as_bytes())
}

/// SHA-256 hex of a node token. Satellites store hashes, never the token.
pub fn hash_node_token(token: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(token.as_bytes()))
}

/// A fresh node token: 64 hex characters from two UUIDs.
pub fn generate_node_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_code_format_and_match() {
        let code = generate_pairing_code();
        assert_eq!(code.len(), 14);
        assert_eq!(code.chars().filter(|c| *c == '-').count(), 2);
        assert!(pairing_code_matches(&code, &code));
        // Separators and case are normalized away for the user.
        let typed = code.to_lowercase().replace('-', " ");
        assert!(pairing_code_matches(&code, &typed));
        assert!(!pairing_code_matches(&code, "AAAA-AAAA-AAAA"));
        assert!(!pairing_code_matches(&code, ""));
    }

    #[test]
    fn token_hash_is_stable() {
        let t = generate_node_token();
        assert_eq!(t.len(), 64);
        assert_eq!(hash_node_token(&t), hash_node_token(&t));
        assert_ne!(hash_node_token(&t), hash_node_token("other"));
    }

    #[test]
    fn node_event_roundtrip() {
        let ev = NodeEvent::Permission {
            request_id: "r1".into(),
            request: PermissionRequest {
                request_id: "r1".into(),
                scope: "exec".into(),
                title: "run ls".into(),
                input: Some("ls".into()),
                options: vec![],
            },
        };
        let json = serde_json::to_string(&ev).unwrap();
        let back: NodeEvent = serde_json::from_str(&json).unwrap();
        match back {
            NodeEvent::Permission { request_id, .. } => assert_eq!(request_id, "r1"),
            _ => panic!("wrong variant"),
        }
    }
}
