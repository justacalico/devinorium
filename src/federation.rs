//! Shared helpers for hub/satellite federation.
//!
//! A hub pairs with satellites (see [`crate::api::federation`]) and calls
//! their `/api/node/*` surface through [`crate::node_client`]; a satellite
//! is a stateless runner serving that surface (see [`crate::satellite`]).

use std::time::Duration;

/// A node counts as online while its last successful probe is this fresh.
/// The hub probes lazily when the node list is read, so this only needs to
/// cover the window between list calls.
pub const ONLINE_WINDOW: Duration = Duration::from_secs(30);

/// Header set by a hub on node calls naming the hub user who made the
/// call, so satellite logs can attribute actions. Only meaningful from a
/// trusted hub; the node API never trusts it for authorization.
pub const PROXY_USER_HEADER: &str = "x-devinorium-proxy-user";

/// Normalize and validate a node base URL: it must be a plain http(s)
/// origin with no userinfo, path, query, or fragment, since API paths are
/// appended verbatim. Anything reachable from the hub is allowed by
/// design — the pairing code and issued token are the gate, and LAN
/// addresses are the point of the feature.
pub fn clean_node_base_url(raw: &str) -> Option<String> {
    let url = raw.trim().trim_end_matches('/');
    if url.len() > 512 {
        return None;
    }
    let parsed = reqwest::Url::parse(url).ok()?;
    let ok_scheme = matches!(parsed.scheme(), "http" | "https");
    let bare = parsed.path() == "/" || parsed.path().is_empty();
    if !ok_scheme
        || parsed.host_str().is_none()
        || !bare
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return None;
    }
    Some(url.to_string())
}

/// Build the HTTP client used for node calls. There is deliberately no
/// overall timeout: run streams proxied through the hub stay open
/// indefinitely. The connect timeout is enough to fail dead nodes quickly.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("federation http client")
}

/// Bounded client for regular node calls (files, git, clone, terminal):
/// generous enough for a slow clone or worktree create, but a wedged node
/// cannot hold a hub request handler open forever.
pub fn bounded_http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(600))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("federation bounded http client")
}

/// Short-timeout client for node probes and lightweight calls where a dead
/// node must not stall a request: 3s connect, 15s total.
pub fn short_http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("federation short http client")
}

#[cfg(test)]
mod tests {
    use super::clean_node_base_url;

    #[test]
    fn clean_node_base_url_accepts_plain_origins() {
        assert_eq!(
            clean_node_base_url("http://192.168.1.10:7878").as_deref(),
            Some("http://192.168.1.10:7878")
        );
        assert_eq!(
            clean_node_base_url("https://node.example.com/").as_deref(),
            Some("https://node.example.com")
        );
        assert!(clean_node_base_url(" http://host:1 ").is_some());
    }

    #[test]
    fn clean_node_base_url_rejects_non_origin_urls() {
        for bad in [
            "ftp://host",
            "http://",
            "not-a-url",
            "http://host/path",
            "http://host/?q=1",
            "http://host/#frag",
            "http://user@host",
            "http://user:pass@host",
        ] {
            assert_eq!(clean_node_base_url(bad), None, "{bad}");
        }
    }
}
