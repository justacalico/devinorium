//! Version detection and update checks for the Devin CLI provider.

use once_cell::sync::Lazy;
use tokio::process::Command;

use super::provider::DevinAcpProvider;
use crate::providers::version::{fetch_latest_version, parse_version_output, ProviderVersion};

/// Manifest published by the Devin CLI installer; its top-level `version`
/// field names the latest promoted release.
const MANIFEST_URL: &str = "https://static.devin.ai/cli/current/manifest.json";

/// `--version` results keyed by command, so revisiting Settings does not
/// spawn a process every time.
static INSTALLED_CACHE: Lazy<mini_moka::sync::Cache<String, String>> = Lazy::new(|| {
    mini_moka::sync::Cache::builder()
        .max_capacity(64)
        .time_to_live(std::time::Duration::from_secs(60))
        .build()
});

impl DevinAcpProvider {
    /// Report the installed binary version and the latest published
    /// version. Both are best effort: a missing binary or an unreachable
    /// manifest leaves the field empty rather than failing.
    pub async fn check_version(&self) -> ProviderVersion {
        self.check_version_at(MANIFEST_URL).await
    }

    /// Same as [`check_version`] but against an explicit manifest URL, so
    /// tests can point the check at a local server.
    async fn check_version_at(&self, manifest_url: &str) -> ProviderVersion {
        let (installed, latest) =
            tokio::join!(self.installed_version(), fetch_latest_version(manifest_url));
        ProviderVersion { installed, latest }
    }

    async fn installed_version(&self) -> Option<String> {
        if let Some(cached) = INSTALLED_CACHE.get(&self.bin) {
            return Some(cached);
        }
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            Command::new(&self.bin)
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
        // Some CLIs print their version to stderr; try stdout first.
        let stdout = String::from_utf8_lossy(&output.stdout);
        let text = if stdout.trim().is_empty() {
            String::from_utf8_lossy(&output.stderr)
        } else {
            stdout
        };
        let version = parse_version_output(&text);
        if let Some(ref v) = version {
            INSTALLED_CACHE.insert(self.bin.clone(), v.clone());
        }
        version
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::future::IntoFuture;

    fn fake_devin(version_line: &str) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fake-devin");
        fs::write(&path, format!("#!/bin/sh\necho '{version_line}'\n")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        (dir, path.to_string_lossy().to_string())
    }

    async fn manifest_server(version: &str) -> String {
        let body = serde_json::json!({"version": version, "platforms": {}});
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = axum::Router::new().route(
            "/manifest.json",
            axum::routing::get(move || {
                let body = body.clone();
                async move { axum::Json(body) }
            }),
        );
        tokio::spawn(axum::serve(listener, app).into_future());
        format!("http://127.0.0.1:{port}/manifest.json")
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn check_version_reports_installed_and_update() {
        let (_dir, bin) = fake_devin("devin 1.0.0 (abc)");
        let provider = DevinAcpProvider::new(bin, "stub".into());
        let url = manifest_server("1.2.3").await;

        let info = provider.check_version_at(&url).await;
        assert_eq!(info.installed.as_deref(), Some("1.0.0"));
        assert_eq!(info.latest.as_deref(), Some("1.2.3"));
        assert!(info.update_available());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn check_version_reports_up_to_date() {
        let (_dir, bin) = fake_devin("devin 3000.6.14 (abc)");
        let provider = DevinAcpProvider::new(bin, "stub".into());
        let url = manifest_server("3000.6.14").await;

        let info = provider.check_version_at(&url).await;
        assert_eq!(info.installed.as_deref(), Some("3000.6.14"));
        assert!(!info.update_available());
    }

    #[tokio::test]
    async fn missing_binary_reports_no_installed_version() {
        let provider = DevinAcpProvider::new("/nonexistent/devin-cli".into(), "stub".into());
        let url = manifest_server("9.9.9").await;

        let info = provider.check_version_at(&url).await;
        assert_eq!(info.installed, None);
        assert_eq!(info.latest.as_deref(), Some("9.9.9"));
        assert!(!info.update_available());
    }
}
