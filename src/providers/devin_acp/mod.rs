//! Devin CLI ACP provider.
//!
//! The provider is split into focused modules:
//! - `provider`: provider struct and lifecycle
//! - `session_config`: ACP session config and interaction mode mapping
//! - `permissions`: permission request handling
//! - `elicitation`: ask/elicitation request handling
//! - `tool_calls`: tool-call and diff merging
//! - `content`: content block and text helpers
//! - `models`: static fallback model catalog
//! - `version`: installed-version detection and update checks

pub mod content;
pub mod elicitation;
pub mod models;
pub mod permissions;
pub mod provider;
pub mod session_config;
pub mod tool_calls;
pub mod version;

pub use models::{static_models, MODELS};
pub use provider::{DevinAcpProvider, PROVIDER_ID, PROVIDER_NAME};
