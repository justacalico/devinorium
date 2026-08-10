//! Client IP extraction and hashing for audit logs.
//!
//! When `trust_proxy` is enabled, the IP is read from `X-Forwarded-For`
//! (first hop) or `X-Real-IP`. Otherwise it comes from the connection's
//! peer address. IPs are never stored raw in audit logs — only a salted
//! hash, so logs cannot be used to reconstruct browsing patterns.

use std::net::SocketAddr;
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
        if let Some(xff) = req.headers().get(header::FORWARDED) {
            if let Ok(s) = xff.to_str() {
                // Parse "for=1.2.3.4" style.
                for part in s.split(';') {
                    let part = part.trim();
                    if let Some(rest) = part.strip_prefix("for=") {
                        return rest.trim_matches('"').to_string();
                    }
                }
            }
        }
        if let Some(xff) = req.headers().get("x-forwarded-for") {
            if let Ok(s) = xff.to_str() {
                if let Some(first) = s.split(',').next() {
                    return first.trim().to_string();
                }
            }
        }
        if let Some(real) = req.headers().get("x-real-ip") {
            if let Ok(s) = real.to_str() {
                return s.trim().to_string();
            }
        }
    }
    // Fall back to peer address from ConnectInfo extension.
    if let Some(ci) = req.extensions().get::<ConnectInfo<SocketAddr>>() {
        return ci.0.ip().to_string();
    }
    "unknown".to_string()
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
}
