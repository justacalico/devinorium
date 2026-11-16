//! Live agent-browser frame feed.
//!
//! The flow is browser-mcp -> server -> frontend:
//!
//! - A run with web access enabled gives the builtin browser MCP server two
//!   env vars, [`FEED_URL_ENV`] and [`FEED_TOKEN_ENV`]. The spawned
//!   `devinorium browser-mcp` reads them and POSTs viewport snapshots back
//!   to whichever devinorium process executes the run (hub or satellite).
//! - That process keeps one [`BrowserFeed`] per thread: `publish` stores the
//!   newest frame and fans it out to viewers subscribed over the browser
//!   WebSocket. The satellite exposes the same feed so the hub can tunnel
//!   a viewer socket onto it.
//!
//! Feeds are view-only: the protocol carries frames and page metadata one
//! way, never input back to the browser.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

/// Env var pointing the browser MCP server at the feed ingest endpoint.
pub const FEED_URL_ENV: &str = "DEVINORIUM_BROWSER_FEED_URL";
/// Env var carrying the bearer token that authorizes feed POSTs.
pub const FEED_TOKEN_ENV: &str = "DEVINORIUM_BROWSER_FEED_TOKEN";

/// Body cap for a feed POST: a base64 JPEG frame plus metadata.
pub const MAX_POST_BODY_BYTES: usize = 4 * 1024 * 1024;

/// Header carrying the feed token on the hub->node feed WebSocket. Kept
/// out of the query string so the credential never lands in request logs.
pub const FEED_TOKEN_HEADER: &str = "x-devinorium-feed-token";

/// Live viewers per feed before the oldest start missing frames.
const BROADCAST_CAPACITY: usize = 16;

/// Cap on registered feeds; past it, feeds nobody watches are evicted.
const FEED_TABLE_CAP: usize = 1024;

/// A feed with no viewers that has not received a post for this long is
/// treated as dead and may be evicted. The token is stable for the life of
/// the thread, so an active feed must never be evicted: browser-mcp learns
/// the token once at spawn and cannot rotate to a new one.
const FEED_IDLE_TTL: std::time::Duration = std::time::Duration::from_secs(30 * 60);

/// What browser-mcp POSTs to the ingest endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedPost {
    pub url: String,
    pub title: String,
    /// Base64 JPEG frame; empty means only the page metadata changed and
    /// viewers should keep the last image.
    #[serde(default)]
    pub data: String,
}

/// The JSON message a feed pushes to a subscribed viewer.
pub fn frame_message(post: &FeedPost) -> String {
    serde_json::json!({
        "type": "frame",
        "url": post.url,
        "title": post.title,
        "data": post.data,
    })
    .to_string()
}

/// Message sent while a thread has no live browser feed.
pub fn idle_message() -> String {
    serde_json::json!({"type": "status", "state": "idle"}).to_string()
}

/// One thread's live browser feed. `latest` keeps the newest merged post so
/// a viewer joining mid-run gets a frame immediately instead of waiting for
/// the next capture.
pub struct BrowserFeed {
    pub token: String,
    latest: Mutex<Option<FeedPost>>,
    last_active: Mutex<std::time::Instant>,
    tx: broadcast::Sender<String>,
}

impl BrowserFeed {
    pub fn new() -> Arc<Self> {
        let mut bytes = [0u8; 32];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut bytes);
        Self::with_token(format!("bf_{}", hex::encode(bytes)))
    }

    /// A feed carrying a caller-chosen token: satellites register the
    /// hub-minted token from the run request rather than minting their own.
    pub fn with_token(token: impl Into<String>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(BROADCAST_CAPACITY);
        Arc::new(Self {
            token: token.into(),
            latest: Mutex::new(None),
            last_active: Mutex::new(std::time::Instant::now()),
            tx,
        })
    }

    /// Store the post and fan it out to subscribers. A metadata-only post
    /// still updates the remembered url/title while keeping the last image
    /// bytes, so `latest` always holds a complete picture.
    pub fn publish(&self, post: FeedPost) {
        {
            let mut latest = self.latest.lock().unwrap_or_else(|e| e.into_inner());
            match latest.as_mut() {
                Some(l) if post.data.is_empty() => {
                    l.url = post.url.clone();
                    l.title = post.title.clone();
                }
                _ => *latest = Some(post.clone()),
            }
        }
        *self.last_active.lock().unwrap_or_else(|e| e.into_inner()) = std::time::Instant::now();
        // An error just means nobody is subscribed yet; `latest` still
        // holds the frame for the next viewer.
        let _ = self.tx.send(frame_message(&post));
    }

    /// Live while a viewer watches or a post arrived within the idle TTL.
    pub fn active(&self) -> bool {
        self.viewer_count() > 0
            || self
                .last_active
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .elapsed()
                < FEED_IDLE_TTL
    }

    /// The viewer message for the newest post, if any was published.
    pub fn latest_message(&self) -> Option<String> {
        self.latest
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(frame_message)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    pub fn viewer_count(&self) -> usize {
        self.tx.receiver_count()
    }
}

/// Feeds keyed by thread id, shared by the ingest route, the viewer
/// WebSocket, and the run path that mints feed tokens.
#[derive(Clone, Default)]
pub struct Feeds {
    inner: Arc<Mutex<HashMap<String, Arc<BrowserFeed>>>>,
}

impl Feeds {
    /// Get or create the thread's feed. The token is stable for the life of
    /// the thread: a session's browser-mcp only learns it once at launch,
    /// so rotating it per send would strand the running feed.
    pub fn for_thread(&self, thread_id: &str) -> Arc<BrowserFeed> {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(feed) = map.get(thread_id) {
            return feed.clone();
        }
        if map.len() >= FEED_TABLE_CAP {
            map.retain(|_, f| f.active());
        }
        let feed = BrowserFeed::new();
        map.insert(thread_id.to_string(), feed.clone());
        feed
    }

    /// The thread's feed without creating one.
    pub fn peek(&self, thread_id: &str) -> Option<Arc<BrowserFeed>> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(thread_id)
            .cloned()
    }

    /// Resolve an ingest token to its feed. Constant-time compare per entry:
    /// feed tokens are bearer secrets, so lookup must not leak which prefix
    /// matched.
    pub fn by_token(&self, token: &str) -> Option<Arc<BrowserFeed>> {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .find(|f| constant_time_eq::constant_time_eq(f.token.as_bytes(), token.as_bytes()))
            .cloned()
    }

    /// Drop the thread's feed; subscribers see the channel close.
    pub fn remove(&self, thread_id: &str) {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(thread_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn post(data: &str) -> FeedPost {
        FeedPost {
            url: "https://a.b".into(),
            title: "t".into(),
            data: data.into(),
        }
    }

    #[test]
    fn publish_stores_latest_and_broadcasts() {
        let feed = BrowserFeed::new();
        let mut rx = feed.subscribe();
        feed.publish(post("aGk="));
        let msg = rx.try_recv().unwrap();
        assert!(msg.contains("\"data\":\"aGk=\""));
        assert_eq!(feed.latest_message(), Some(msg));
    }

    #[test]
    fn meta_only_post_keeps_last_frame_but_sends_meta() {
        let feed = BrowserFeed::new();
        let mut rx = feed.subscribe();
        feed.publish(post("aGk="));
        feed.publish(FeedPost {
            url: "https://c.d".into(),
            title: "t2".into(),
            data: String::new(),
        });
        let _ = rx.try_recv().unwrap();
        let msg = rx.try_recv().unwrap();
        assert!(msg.contains("https://c.d") && msg.contains("\"data\":\"\""));
        // The stored latest still carries the image bytes for new viewers.
        let latest = feed.latest_message().unwrap();
        assert!(latest.contains("\"data\":\"aGk=\""));
        assert!(latest.contains("https://c.d"));
    }

    #[test]
    fn token_lookup_is_exact_and_stable_per_thread() {
        let feeds = Feeds::default();
        assert!(feeds.by_token("bf_nope").is_none());
        let a = feeds.for_thread("t1");
        assert!(feeds.by_token(&a.token).is_some());
        assert!(feeds.by_token("bf_nope2").is_none());
        // Same thread keeps the same feed and token.
        assert_eq!(feeds.for_thread("t1").token, a.token);
        feeds.remove("t1");
        assert!(feeds.by_token(&a.token).is_none());
    }
}
