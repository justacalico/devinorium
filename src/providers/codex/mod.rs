//! Codex provider.
//!
//! Unlike the ACP-based providers, Codex CLI has no `acp` subcommand — its
//! embedding surface is `codex app-server --stdio`, a JSON-RPC protocol the
//! CLI ships itself. This module implements just enough of it for
//! Devinorium:
//! - `rpc`: the newline-delimited JSON-RPC transport over the child's stdio
//! - `wire`: the protocol types we decode
//! - `events`: notification → message-part translation
//! - `approvals`: server→client requests (approvals, user input, elicitations)
//!   and the permission-mode → sandbox mapping
//! - `models`: `model/list` catalog
//! - `version`: installed/latest version reporting
//! - `provider`: the [`Provider`] impl and per-prompt orchestration

pub mod approvals;
pub mod events;
pub mod models;
mod provider;
pub mod rpc;
mod version;
pub mod wire;

pub use provider::{CodexProvider, PROVIDER_ID};
