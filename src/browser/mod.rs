//! Headless browser for agents.
//!
//! When the owner enables "web access" in settings, `send` appends a
//! builtin stdio MCP server (`devinorium-browser`) to the run's MCP list.
//! The agent then spawns `devinorium browser-mcp` — this binary — on
//! whichever machine executes it (hub or satellite), so the browser always
//! runs server-side and works with no client connected.
//!
//! The subprocess speaks MCP over newline-delimited JSON-RPC on stdio and
//! drives a real Chromium through the DevTools Protocol: navigate, click,
//! type, scroll, screenshot, and a text snapshot that tags interactive
//! elements with stable `[ref=N]` handles.

pub mod action;
mod engine;
mod mcp;
mod tools;

use std::path::PathBuf;

pub use mcp::run_stdio;

/// Environment override for the browser binary.
const BROWSER_BINARY_ENV: &str = "DEVINORIUM_BROWSER_BINARY";

/// Executable names probed on PATH, in preference order.
const BROWSER_CANDIDATES: &[&str] = &[
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
    "chrome",
    "microsoft-edge",
    "microsoft-edge-stable",
    "brave",
    "brave-browser",
    "headless_shell",
];

/// Locate a Chromium-family binary: the explicit env override first (must
/// be an existing file), then the candidate names on PATH.
pub fn find_browser_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(BROWSER_BINARY_ENV) {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Some(path);
        }
        tracing::warn!(
            path = %path.display(),
            "{BROWSER_BINARY_ENV} does not point at a file; falling back to PATH lookup"
        );
    }
    BROWSER_CANDIDATES
        .iter()
        .find_map(|name| which::which(name).ok())
}

/// One piece of `tools/call` result content.
#[derive(Debug, Clone, PartialEq)]
pub enum ToolContent {
    Text(String),
    /// Raw PNG bytes; serialized as MCP `image` content (base64).
    ImagePng(Vec<u8>),
}

impl ToolContent {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            ToolContent::Text(t) => serde_json::json!({"type": "text", "text": t}),
            ToolContent::ImagePng(bytes) => serde_json::json!({
                "type": "image",
                "data": base64::Engine::encode(
                    &base64::engine::general_purpose::STANDARD,
                    bytes,
                ),
                "mimeType": "image/png",
            }),
        }
    }
}
