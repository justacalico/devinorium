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
/// appended verbatim. Plaintext http is only accepted for loopback and
/// private-network hosts: a remote http node would expose the node token
/// and all proxied traffic to on-path observers. LAN addresses are the
/// point of the feature, so private ranges stay reachable.
pub async fn clean_node_base_url(raw: &str) -> Option<String> {
    let url = raw.trim().trim_end_matches('/');
    if url.len() > 512 {
        return None;
    }
    let parsed = reqwest::Url::parse(url).ok()?;
    let ok_scheme = match parsed.scheme() {
        "https" => true,
        "http" => plaintext_node_host(parsed.host_str()).await,
        _ => false,
    };
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

/// Whether an address is LAN-confined, i.e. plaintext http toward it
/// cannot route onto the public internet. 100.64/10 is CGNAT, which is
/// also the Tailscale range — tailnet transport is WireGuard, so the http
/// scheme only wraps the API framing inside the tunnel.
fn plaintext_node_ip(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(ip) => {
            ip.is_loopback()
                || ip.is_private()
                || ip.is_link_local()
                || (ip.octets()[0] == 100 && ip.octets()[1] & 0xC0 == 0x40)
        }
        std::net::IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
                || ip.to_ipv4_mapped().is_some_and(plaintext_node_ip_v4_map)
        }
    }
}

fn plaintext_node_ip_v4_map(v4: std::net::Ipv4Addr) -> bool {
    plaintext_node_ip(std::net::IpAddr::V4(v4))
}

/// Hosts where plaintext http traffic stays on the local machine or LAN.
/// Named hosts must additionally resolve *only* to LAN-confined addresses:
/// a `.internal` or single-label name can be pointed at a public IP through
/// search-domain or DHCP DNS, and cleartext to it would carry the node
/// token onto the internet.
async fn plaintext_node_host(host: Option<&str>) -> bool {
    let Some(host) = host.map(|h| h.trim_end_matches('.')) else {
        return false;
    };
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return plaintext_node_ip(ip);
    }
    // Anything left with a colon is a v6 literal in some bracketing; IP
    // rules above already decided those.
    if host.contains(':') {
        return false;
    }
    // localhost resolves to loopback on every sane resolver; skip lookup.
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    let lan_named = host.ends_with(".local")
        || host.ends_with(".internal")
        || host.ends_with(".lan")
        || host.ends_with(".home.arpa")
        || host.ends_with(".ts.net")
        || !host.contains('.');
    if !lan_named {
        return false;
    }
    match tokio::net::lookup_host(format!("{host}:0")).await {
        Ok(addrs) => {
            let addrs: Vec<_> = addrs.collect();
            !addrs.is_empty() && addrs.iter().all(|a| plaintext_node_ip(a.ip()))
        }
        Err(_) => false,
    }
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

    #[tokio::test]
    async fn clean_node_base_url_accepts_plain_origins() {
        assert_eq!(
            clean_node_base_url("http://192.168.1.10:7878")
                .await
                .as_deref(),
            Some("http://192.168.1.10:7878")
        );
        assert_eq!(
            clean_node_base_url("https://node.example.com/")
                .await
                .as_deref(),
            Some("https://node.example.com")
        );
        for ok in [
            "http://100.64.1.2:7878",
            "http://dev.localhost:7878",
            "http://localhost.:7878",
            "http://[::ffff:192.168.1.1]:7878",
        ] {
            assert!(clean_node_base_url(ok).await.is_some(), "{ok}");
        }
        // LAN-named hosts additionally require the name to resolve only to
        // LAN addresses; `.invalid` is a guaranteed NXDOMAIN.
        assert!(clean_node_base_url("http://no-such-node.invalid:7878")
            .await
            .is_none());
    }

    #[tokio::test]
    async fn clean_node_base_url_rejects_remote_plaintext() {
        // Node tokens and all proxied traffic ride this connection, so
        // cleartext is only acceptable where it cannot leave the LAN.
        for bad in [
            "http://node.example.com",
            "http://203.0.113.9:7878",
            "http://8.8.8.8",
            "http://[2606:4700:4700::1111]",
        ] {
            assert_eq!(clean_node_base_url(bad).await, None, "{bad}");
        }
        assert_eq!(
            clean_node_base_url("https://node.example.com")
                .await
                .as_deref(),
            Some("https://node.example.com")
        );
    }

    #[tokio::test]
    async fn clean_node_base_url_rejects_non_origin_urls() {
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
            assert_eq!(clean_node_base_url(bad).await, None, "{bad}");
        }
    }
}
