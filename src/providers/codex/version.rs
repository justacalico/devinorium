//! Version detection for the Codex CLI: installed `codex --version` plus the
//! latest published `@openai/codex` release from the npm registry.

use once_cell::sync::Lazy;
use tokio::process::Command;

use crate::providers::version::{fetch_latest_version, parse_version_output, ProviderVersion};

const MANIFEST_URL: &str = "https://registry.npmjs.org/@openai%2Fcodex/latest";

static INSTALLED_CACHE: Lazy<mini_moka::sync::Cache<String, String>> = Lazy::new(|| {
    mini_moka::sync::Cache::builder()
        .max_capacity(8)
        .time_to_live(std::time::Duration::from_secs(60))
        .build()
});

/// Best-effort installed + latest version for the configured codex binary.
pub async fn check_version(bin: &str) -> ProviderVersion {
    let (installed, latest) =
        tokio::join!(installed_version(bin), fetch_latest_version(MANIFEST_URL));
    ProviderVersion { installed, latest }
}

async fn installed_version(bin: &str) -> Option<String> {
    if let Some(cached) = INSTALLED_CACHE.get(&bin.to_string()) {
        return Some(cached);
    }
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        Command::new(bin)
            .arg("--version")
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let text = if stdout.trim().is_empty() {
        String::from_utf8_lossy(&output.stderr)
    } else {
        stdout
    };
    let version = parse_version_output(&text);
    if let Some(ref v) = version {
        INSTALLED_CACHE.insert(bin.to_string(), v.clone());
    }
    version
}
