//! Live viewport feed back to the devinorium server.
//!
//! When the run that spawned us set `DEVINORIUM_BROWSER_FEED_URL` /
//! `DEVINORIUM_BROWSER_FEED_TOKEN` (injected into the builtin server's MCP
//! env), the engine mirrors the page back to the hub: a JPEG screenshot on
//! a short interval plus the current url/title, POSTed with the feed token
//! as a bearer credential. The feed is strictly one-way — nothing here ever
//! feeds viewer input back into the page.

use std::time::Duration;

use chromiumoxide::cdp::browser_protocol::page::CaptureScreenshotFormat;
use chromiumoxide::page::ScreenshotParams;
use chromiumoxide::Page;

/// Frame cadence. ~1.3 fps reads as live without flooding the feed.
const CAPTURE_INTERVAL: Duration = Duration::from_millis(750);
/// Screenshot jpeg quality: small enough for a ~150 KB frame.
const JPEG_QUALITY: i64 = 55;
/// Per-POST timeout; a hung server must not stall the capture loop.
const POST_TIMEOUT: Duration = Duration::from_secs(5);
/// Consecutive capture failures before the loop gives up: a dead page can
/// never produce another frame, and retrying it forever just burns CPU.
const MAX_CONSECUTIVE_FAILURES: u32 = 20;

/// Feed destination from the MCP server environment, when the run enabled
/// browser streaming. Both vars must be present; a URL that is not http(s)
/// is ignored rather than spawning a task that can only fail.
#[derive(Debug, Clone, PartialEq)]
pub struct FeedConfig {
    pub url: String,
    pub token: String,
}

impl FeedConfig {
    pub fn from_env() -> Option<Self> {
        Self::from(|k| std::env::var(k).ok())
    }

    fn from(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let url = get(crate::browser_feed::FEED_URL_ENV).filter(|u| !u.is_empty())?;
        let token = get(crate::browser_feed::FEED_TOKEN_ENV).filter(|t| !t.is_empty())?;
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return None;
        }
        Some(Self { url, token })
    }
}

/// Spawn the capture loop for a live page. Runs until the process exits or
/// the page stops producing frames.
pub fn spawn(page: Page, cfg: FeedConfig) {
    tokio::spawn(run(page, cfg));
}

async fn run(page: Page, cfg: FeedConfig) {
    let client = match reqwest::Client::builder().timeout(POST_TIMEOUT).build() {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(error = %e, "browser feed client could not be built");
            return;
        }
    };

    let mut last_frame: Vec<u8> = Vec::new();
    let mut last_url = String::new();
    let mut last_title = String::new();
    let mut failures = 0u32;
    // POST failures get their own budget: a dead feed (stale token after a
    // hub restart) would otherwise keep re-encoding the same frame and
    // re-POSTing forever.
    let mut post_failures = 0u32;

    let mut interval = tokio::time::interval(CAPTURE_INTERVAL);
    loop {
        interval.tick().await;

        let bytes = match page
            .screenshot(
                ScreenshotParams::builder()
                    .format(CaptureScreenshotFormat::Jpeg)
                    .quality(JPEG_QUALITY)
                    .build(),
            )
            .await
        {
            Ok(b) => b,
            Err(e) => {
                failures += 1;
                if failures >= MAX_CONSECUTIVE_FAILURES {
                    tracing::debug!(error = %e, "browser feed stopped: page no longer responds");
                    return;
                }
                continue;
            }
        };
        failures = 0;

        let url = page.url().await.ok().flatten().unwrap_or_default();
        let title = page.get_title().await.ok().flatten().unwrap_or_default();

        let frame_changed = bytes != last_frame;
        let meta_changed = url != last_url || title != last_title;
        if !frame_changed && !meta_changed {
            continue;
        }

        use base64::Engine;
        let post = crate::browser_feed::FeedPost {
            url: url.clone(),
            title: title.clone(),
            // A metadata-only change keeps the last frame server-side.
            data: if frame_changed {
                base64::engine::general_purpose::STANDARD.encode(&bytes)
            } else {
                String::new()
            },
        };
        match client
            .post(&cfg.url)
            .bearer_auth(&cfg.token)
            .json(&post)
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                post_failures = 0;
                if frame_changed {
                    last_frame = bytes;
                }
                last_url = url;
                last_title = title;
            }
            Ok(resp) => {
                let status = resp.status();
                tracing::debug!(status = %status, "browser feed post rejected");
                // A 401/403 means the feed is gone for good: the token is
                // fixed at spawn, so it can never become valid again.
                if status == reqwest::StatusCode::UNAUTHORIZED
                    || status == reqwest::StatusCode::FORBIDDEN
                {
                    return;
                }
                post_failures += 1;
            }
            Err(e) => {
                tracing::debug!(error = %e, "browser feed post failed");
                post_failures += 1;
            }
        }
        if post_failures >= MAX_CONSECUTIVE_FAILURES {
            tracing::debug!("browser feed stopped: server keeps rejecting posts");
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn cfg_from(map: &HashMap<&str, &str>) -> Option<FeedConfig> {
        FeedConfig::from(|k| map.get(k).map(|v| v.to_string()))
    }

    #[test]
    fn feed_config_requires_url_token_and_http() {
        let mut env = HashMap::new();
        assert!(cfg_from(&env).is_none());

        env.insert(
            crate::browser_feed::FEED_URL_ENV,
            "http://127.0.0.1:7878/api/browser-feed",
        );
        assert!(cfg_from(&env).is_none(), "missing token");

        env.insert(crate::browser_feed::FEED_TOKEN_ENV, "bf_abc");
        let cfg = cfg_from(&env).unwrap();
        assert_eq!(cfg.token, "bf_abc");

        env.insert(crate::browser_feed::FEED_URL_ENV, "file:///etc/passwd");
        assert!(cfg_from(&env).is_none(), "non-http url is rejected");
    }
}
