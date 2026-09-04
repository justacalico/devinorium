//! Provider version detection and update checks.
//!
//! Everything here is best effort: a missing binary, a non-parseable
//! version string, or an unreachable update manifest yields `None`/`false`
//! rather than an error, so the API can always respond with whatever was
//! discovered.

use once_cell::sync::Lazy;
use regex::Regex;
use serde::Serialize;

/// Version details for a provider's backing binary.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ProviderVersion {
    /// Version reported by the installed binary, when detectable.
    pub installed: Option<String>,
    /// Latest published version, when the provider exposes one.
    pub latest: Option<String>,
}

impl ProviderVersion {
    /// True when a published version newer than the installed one exists.
    pub fn update_available(&self) -> bool {
        match (&self.installed, &self.latest) {
            (Some(installed), Some(latest)) => is_newer(latest, installed),
            _ => false,
        }
    }
}

/// Extract a `x.y[.z...]` version from `<cmd> --version` output, e.g.
/// `devin 3000.6.14 (18033302)` or `v1.2.3`. The match must span a whole
/// whitespace-delimited token so unrelated numbers (dates, counts) are not
/// picked up.
pub fn parse_version_output(output: &str) -> Option<String> {
    static VERSION_RE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^v?(\d+\.\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.\-]+)?)$").expect("version re")
    });
    output
        .split_whitespace()
        .find_map(|tok| VERSION_RE.captures(tok).map(|c| c[1].to_string()))
}

/// Dotted numeric compare: true when `latest` sorts above `installed`.
/// Non-numeric or empty inputs never count as newer. Pre-release suffixes
/// are not compared beyond "a release is newer than a pre-release of the
/// same numeric core".
pub fn is_newer(latest: &str, installed: &str) -> bool {
    let (Some(mut a), Some(mut b)) = (segments(latest), segments(installed)) else {
        return false;
    };
    let len = a.len().max(b.len());
    a.resize(len, 0);
    b.resize(len, 0);
    if a == b {
        // Same numeric core: a final release beats a pre-release.
        return is_prerelease(installed) && !is_prerelease(latest);
    }
    a > b
}

fn is_prerelease(version: &str) -> bool {
    version.contains('-')
}

fn segments(version: &str) -> Option<Vec<u64>> {
    let version = version.trim().trim_start_matches('v');
    // Drop any pre-release / build suffix before splitting segments.
    let core = version.split(['-', '+']).next().unwrap_or_default();
    core.split('.')
        .map(|p| p.parse::<u64>().ok())
        .collect::<Option<Vec<u64>>>()
        .filter(|v| !v.is_empty())
}

/// GET a JSON document and read its top-level `version` string.
/// Returns `None` on any network, status, or parse failure. Successful
/// lookups are cached briefly so repeated checks stay cheap.
pub async fn fetch_latest_version(url: &str) -> Option<String> {
    static HTTP: Lazy<reqwest::Client> = Lazy::new(|| {
        reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .expect("reqwest client")
    });
    static MANIFEST_CACHE: Lazy<mini_moka::sync::Cache<String, String>> = Lazy::new(|| {
        mini_moka::sync::Cache::builder()
            .max_capacity(32)
            .time_to_live(std::time::Duration::from_secs(600))
            .build()
    });
    if let Some(cached) = MANIFEST_CACHE.get(&url.to_string()) {
        return Some(cached);
    }
    let version: String = HTTP
        .get(url)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json::<serde_json::Value>()
        .await
        .ok()?
        .get("version")?
        .as_str()?
        .to_string();
    MANIFEST_CACHE.insert(url.to_string(), version.clone());
    Some(version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::IntoFuture;

    #[test]
    fn parses_devin_version_line() {
        assert_eq!(
            parse_version_output("devin 3000.6.14 (18033302)"),
            Some("3000.6.14".to_string())
        );
    }

    #[test]
    fn parses_prefixed_and_suffixed_versions() {
        assert_eq!(
            parse_version_output("tool v1.2.3"),
            Some("1.2.3".to_string())
        );
        assert_eq!(
            parse_version_output("2.0.0-beta.1"),
            Some("2.0.0-beta.1".to_string())
        );
    }

    #[test]
    fn parse_ignores_non_version_tokens() {
        // A date token with trailing punctuation does not match, so the
        // real version later in the line wins.
        assert_eq!(
            parse_version_output("Built 2026.06.14, devin version 1.2.3"),
            Some("1.2.3".to_string())
        );
    }

    #[test]
    fn parse_returns_none_without_version() {
        assert_eq!(parse_version_output("no version here"), None);
        assert_eq!(parse_version_output("build 12345"), None);
        assert_eq!(parse_version_output(""), None);
    }

    #[test]
    fn is_newer_compares_segments_numerically() {
        assert!(is_newer("3000.6.15", "3000.6.14"));
        assert!(is_newer("3001.0.0", "3000.6.14"));
        assert!(!is_newer("3000.6.14", "3000.6.14"));
        assert!(!is_newer("3000.6.14", "3000.6.15"));
        // Missing trailing segments compare as zero.
        assert!(is_newer("1.2.1", "1.2"));
        assert!(!is_newer("1.2", "1.2.0"));
        assert!(!is_newer("1.2", "1.2.1"));
        // Numeric, not lexicographic: 9 < 10.
        assert!(is_newer("1.10.0", "1.9.0"));
        // A final release is newer than a pre-release of the same core.
        assert!(is_newer("1.0.0", "1.0.0-beta.1"));
        assert!(!is_newer("1.0.0-beta.1", "1.0.0"));
    }

    #[test]
    fn is_newer_rejects_non_numeric() {
        assert!(!is_newer("latest", "1.2.3"));
        assert!(!is_newer("1.2.3", "unknown"));
        assert!(!is_newer("", "1.2.3"));
    }

    #[test]
    fn update_available_requires_both_versions() {
        assert!(ProviderVersion {
            installed: Some("1.0.0".into()),
            latest: Some("1.0.1".into()),
        }
        .update_available());
        assert!(!ProviderVersion {
            installed: Some("1.0.0".into()),
            latest: None,
        }
        .update_available());
        assert!(!ProviderVersion {
            installed: None,
            latest: Some("1.0.1".into()),
        }
        .update_available());
        assert!(!ProviderVersion::default().update_available());
    }

    #[tokio::test]
    async fn fetch_latest_version_reads_manifest() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = axum::Router::new().route(
            "/manifest.json",
            axum::routing::get(|| async {
                axum::Json(serde_json::json!({"version": "9.9.9", "platforms": {}}))
            }),
        );
        tokio::spawn(axum::serve(listener, app).into_future());

        let url = format!("http://127.0.0.1:{port}/manifest.json");
        assert_eq!(fetch_latest_version(&url).await, Some("9.9.9".to_string()));
    }

    #[tokio::test]
    async fn fetch_latest_version_handles_failures() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = axum::Router::new()
            .route(
                "/missing-field",
                axum::routing::get(|| async { axum::Json(serde_json::json!({"platforms": {}})) }),
            )
            .route(
                "/error",
                axum::routing::get(|| async { axum::http::StatusCode::INTERNAL_SERVER_ERROR }),
            );
        tokio::spawn(axum::serve(listener, app).into_future());

        let base = format!("http://127.0.0.1:{port}");
        assert_eq!(
            fetch_latest_version(&format!("{base}/missing-field")).await,
            None
        );
        assert_eq!(fetch_latest_version(&format!("{base}/error")).await, None);
        // Nothing listening on this port.
        assert_eq!(fetch_latest_version("http://127.0.0.1:1/x").await, None);
    }
}
