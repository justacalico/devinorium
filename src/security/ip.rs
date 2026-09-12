//! Client IP extraction and hashing for audit logs.
//!
//! When `trust_proxy` is enabled, the IP is read from `X-Forwarded-For`
//! (first hop) or `X-Real-IP`. Otherwise it comes from the connection's
//! peer address. IPs are never stored raw in audit logs — only a salted
//! hash, so logs cannot be used to reconstruct browsing patterns.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::extract::{ConnectInfo, Request};
use axum::http::header;
use axum::middleware::Next;
use axum::response::Response;
use sha2::{Digest, Sha256};

/// The client IP, injected as a request extension by [`extract_client_ip`].
#[derive(Debug, Clone)]
pub struct ClientIp(pub Arc<str>);

/// Middleware: determine the client IP and store it in request extensions.
pub async fn extract_client_ip(trust_proxy: bool, req: Request, next: Next) -> Response {
    let ip = client_ip(&req, trust_proxy);
    let mut req = req;
    req.extensions_mut().insert(ClientIp(Arc::from(ip)));
    next.run(req).await
}

fn client_ip(req: &Request, trust_proxy: bool) -> String {
    if trust_proxy {
        if let Some(s) = req
            .headers()
            .get(header::FORWARDED)
            .and_then(|h| h.to_str().ok())
        {
            // First element, "for=1.2.3.4" style.
            if let Some(first) = s.split(',').next() {
                for part in first.split(';') {
                    if let Some(rest) = part.trim().strip_prefix("for=") {
                        if let Some(ip) = parse_forwarded_ip(rest) {
                            return ip;
                        }
                    }
                }
            }
        }
        if let Some(s) = req
            .headers()
            .get("x-forwarded-for")
            .and_then(|h| h.to_str().ok())
        {
            if let Some(first) = s.split(',').next() {
                if let Some(ip) = parse_forwarded_ip(first) {
                    return ip;
                }
            }
        }
        if let Some(s) = req.headers().get("x-real-ip").and_then(|h| h.to_str().ok()) {
            if let Some(ip) = parse_forwarded_ip(s) {
                return ip;
            }
        }
    }
    // Fall back to peer address from ConnectInfo extension.
    if let Some(ci) = req.extensions().get::<ConnectInfo<SocketAddr>>() {
        return ci.0.ip().to_string();
    }
    "unknown".to_string()
}

/// Normalize a proxy header value to a canonical IP string. Accepts a bare
/// IP or an `ip:port` / `[v6]:port` socket address; anything else (garbage
/// or RFC 7239 obfuscated identifiers like `for=_hidden`) is rejected so
/// attacker-controlled strings cannot become rate-limit keys.
fn parse_forwarded_ip(raw: &str) -> Option<String> {
    let s = raw.trim().trim_matches('"').trim();
    s.parse::<IpAddr>()
        .or_else(|_| s.parse::<SocketAddr>().map(|a| a.ip()))
        .ok()
        .map(|ip| ip.to_string())
}

/// Read the client IP from request extensions (set by [`extract_client_ip`]).
pub fn from_req(req: &Request) -> String {
    req.extensions()
        .get::<ClientIp>()
        .map(|c| c.0.to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Salted SHA-256 hash of an IP for audit storage (truncated to 16 hex chars).
pub fn ip_hash(ip: &str, salt: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(ip.as_bytes());
    hasher.update(salt);
    let digest = hasher.finalize();
    hex::encode(&digest[..8])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req_with(headers: &[(&str, &str)]) -> Request {
        let mut b = Request::builder();
        for (k, v) in headers {
            b = b.header(*k, *v);
        }
        b.body(axum::body::Body::empty()).unwrap()
    }

    #[test]
    fn ip_hash_is_stable_and_distinct() {
        let salt = b"pepper";
        let a = ip_hash("1.2.3.4", salt);
        let b = ip_hash("1.2.3.4", salt);
        let c = ip_hash("5.6.7.8", salt);
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn xff_first_hop_wins() {
        let req = req_with(&[("x-forwarded-for", "1.2.3.4, 5.6.7.8")]);
        assert_eq!(client_ip(&req, true), "1.2.3.4");
    }

    #[test]
    fn forwarded_for_parses_quoted_and_ported() {
        let req = req_with(&[(header::FORWARDED.as_str(), "for=\"1.2.3.4\"")]);
        assert_eq!(client_ip(&req, true), "1.2.3.4");
        let req = req_with(&[(header::FORWARDED.as_str(), "for=1.2.3.4:5678")]);
        assert_eq!(client_ip(&req, true), "1.2.3.4");
        let req = req_with(&[(header::FORWARDED.as_str(), "for=\"[2001:db8::1]:443\"")]);
        assert_eq!(client_ip(&req, true), "2001:db8::1");
    }

    #[test]
    fn garbage_header_falls_through_to_next_source() {
        let req = req_with(&[("x-forwarded-for", "not-an-ip"), ("x-real-ip", "9.9.9.9")]);
        assert_eq!(client_ip(&req, true), "9.9.9.9");
    }

    #[test]
    fn garbage_everywhere_falls_back_to_peer() {
        let garbage = "x".repeat(5000);
        let mut req = req_with(&[("x-forwarded-for", garbage.as_str())]);
        let peer: SocketAddr = "10.0.0.1:1234".parse().unwrap();
        req.extensions_mut().insert(ConnectInfo(peer));
        assert_eq!(client_ip(&req, true), "10.0.0.1");
    }

    #[test]
    fn proxy_headers_ignored_without_trust() {
        let req = req_with(&[("x-forwarded-for", "1.2.3.4")]);
        assert_eq!(client_ip(&req, false), "unknown");
    }

    #[test]
    fn ipv6_is_normalized() {
        let req = req_with(&[("x-forwarded-for", "2001:0DB8:0000::0001")]);
        assert_eq!(client_ip(&req, true), "2001:db8::1");
    }
}
