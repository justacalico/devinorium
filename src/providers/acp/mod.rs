//! ACP (Agent Client Protocol) provider.
//!
//! Agents that speak ACP over stdio share one implementation here, split into
//! focused modules:
//! - `spec`: per-agent differences (Devin CLI vs OpenCode)
//! - `provider`: provider struct and lifecycle
//! - `session_config`: ACP session config and interaction mode mapping
//! - `permissions`: permission request handling
//! - `elicitation`: ask/elicitation request handling
//! - `tool_calls`: tool-call and diff merging
//! - `content`: content block and text helpers
//! - `models`: static fallback model catalogs and CLI output parsing
//! - `version`: installed-version detection and update checks

pub mod content;
pub mod elicitation;
pub mod models;
pub mod permissions;
pub mod provider;
pub mod session_config;
pub mod spec;
pub mod tool_calls;
pub mod version;

pub use provider::AcpProvider;
pub use spec::AgentKind;
