//! CSRF protection via Origin/Referer validation for state-changing requests.
//!
//! Combined with `SameSite=Strict` cookies, this provides defense in depth.
//! For POST/PUT/PATCH/DELETE requests, the `Origin` (or `Referer`) header
//! must be present and its host must match the request's `Host` header, or
//! match an explicitly allowed origin from config.

use axum::extract::Request;
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

/// Middleware: reject state-changing requests whose origin is not allowed.
///
/// `allowed_origin` is an optional explicit origin (scheme://host[:port])
/// from config. When set, the request Origin must equal it. When unset, the
/// Origin/Referer host must match the request Host header.
pub async fn csrf_origin_check(
    allowed_origin: Option<String>,
    req: Request,
    next: Next,
) -> Response {
    let method = req.method().clone();
    let is_state_change = matches!(
        method,
        axum::http::Method::POST
            | axum::http::Method::PUT
            | axum::http::Method::PATCH
            | axum::http::Method::DELETE
    );
    if !is_state_change {
        return next.run(req).await;
    }

    // Bearer tokens are not vulnerable to CSRF; skip the origin check.
    if has_bearer_auth(req.headers()) {
        tracing::debug!("csrf: skipping origin check for bearer token request");
        return next.run(req).await;
    }

    let host = req
        .headers()
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("")
        .to_string();

    if let Some(ref allowed) = allowed_origin {
        if origin_ok_explicit(req.headers(), allowed) {
            return next.run(req).await;
        }
    } else if origin_ok_same_host(req.headers(), &host) {
        return next.run(req).await;
    }

    (StatusCode::FORBIDDEN, "cross-origin request rejected").into_response()
}

fn origin_ok_explicit(headers: &HeaderMap, allowed: &str) -> bool {
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|h| h.to_str().ok()) {
        return origin == allowed;
    }
    if let Some(referer) = headers.get(header::REFERER).and_then(|h| h.to_str().ok()) {
        if let Ok(uri) = referer.parse::<axum::http::Uri>() {
            let composed = format!(
                "{}://{}",
                uri.scheme_str().unwrap_or(""),
                uri.authority().map(|a| a.as_str()).unwrap_or("")
            );
            return composed == allowed;
        }
    }
    false
}

fn has_bearer_auth(headers: &HeaderMap) -> bool {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .is_some_and(|s| s.trim().starts_with("Bearer "))
}

fn origin_ok_same_host(headers: &HeaderMap, host: &str) -> bool {
    /// Extract the hostname (without port) from a `host:port` string.
    fn hostname(s: &str) -> &str {
        // Strip port if present (e.g. "127.0.0.1:7878" -> "127.0.0.1").
        // Also handles IPv6 brackets like "[::1]:8080".
        if let Some(idx) = s.rfind(':') {
            // Don't strip if this looks like an IPv6 address without port.
            if !s.starts_with('[') || s[idx..].starts_with("]:") {
                return &s[..idx];
            }
        }
        s
    }
    let check = |uri_str: &str| -> bool {
        let uri = match uri_str.parse::<axum::http::Uri>() {
            Ok(u) => u,
            Err(_) => return false,
        };
        let origin_host = uri.authority().map(|a| a.as_str()).unwrap_or("");
        hostname(origin_host) == hostname(host)
    };
    if let Some(origin) = headers.get(header::ORIGIN).and_then(|h| h.to_str().ok()) {
        return check(origin);
    }
    if let Some(referer) = headers.get(header::REFERER).and_then(|h| h.to_str().ok()) {
        return check(referer);
    }
    // No Origin/Referer at all on a state-changing request: reject.
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Method;

    fn req(method: Method, origin: Option<&str>, host: &str) -> Request {
        let mut builder = Request::builder().method(method).uri("/");
        if let Some(o) = origin {
            builder = builder.header(header::ORIGIN, o);
        }
        builder = builder.header(header::HOST, host);
        builder.body(Body::empty()).unwrap()
    }

    #[test]
    fn same_host_origin_allowed() {
        assert!(origin_ok_same_host(
            &req(Method::POST, Some("http://example.com"), "example.com").headers(),
            "example.com"
        ));
    }

    #[test]
    fn cross_host_origin_rejected() {
        assert!(!origin_ok_same_host(
            &req(Method::POST, Some("http://evil.com"), "example.com").headers(),
            "example.com"
        ));
    }

    #[test]
    fn missing_origin_rejected() {
        assert!(!origin_ok_same_host(
            &req(Method::POST, None, "example.com").headers(),
            "example.com"
        ));
    }

    #[test]
    fn bearer_auth_skips_origin_check() {
        let mut r = req(Method::POST, None, "example.com");
        r.headers_mut().insert(
            header::AUTHORIZATION,
            "Bearer abc123".parse().unwrap(),
        );
        assert!(has_bearer_auth(r.headers()));
    }

    #[test]
    fn plain_authorization_is_not_bearer() {
        let mut r = req(Method::POST, None, "example.com");
        r.headers_mut().insert(header::AUTHORIZATION, "abc123".parse().unwrap());
        assert!(!has_bearer_auth(r.headers()));
    }
}
