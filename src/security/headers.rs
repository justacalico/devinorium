//! Security headers middleware.
//!
//! Sets a strict Content-Security-Policy plus the standard hardening headers
//! on every response.

use axum::http::{header, HeaderValue, Response};
use axum::middleware::Next;
use axum::extract::Request;

/// A strict CSP. `connect-src 'self'` allows fetch/XHR/WebSocket to the same
/// origin. `img-src 'self' data: blob:` allows inline image previews.
/// `script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline'` allows the Flutter
/// web bootstrap loader (which uses an inline import() script) and WASM
/// execution. The Flutter web renderer loads CanvasKit and the Roboto font
/// from `https://www.gstatic.com` / `https://fonts.gstatic.com`, so those
/// origins are allow-listed in the relevant directives.
pub fn csp_value() -> &'static str {
    "default-src 'self'; \
     script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline' https://www.gstatic.com; \
     style-src 'self' 'unsafe-inline'; \
     img-src 'self' data: blob:; \
     font-src 'self' https://fonts.gstatic.com; \
     connect-src 'self' https://www.gstatic.com https://fonts.gstatic.com; \
     frame-ancestors 'none'; \
     base-uri 'self'; \
     form-action 'self'; \
     object-src 'none'"
}

/// Middleware: apply security headers to every response.
pub async fn security_headers(req: Request, next: Next) -> Response<axum::body::Body> {
    let mut resp = next.run(req).await;
    let headers = resp.headers_mut();
    set_if_absent(headers, header::X_CONTENT_TYPE_OPTIONS, "nosniff");
    set_if_absent(headers, header::X_FRAME_OPTIONS, "DENY");
    set_if_absent(headers, header::REFERRER_POLICY, "no-referrer");
    set_if_absent(headers, header::CONTENT_SECURITY_POLICY, csp_value());
    set_if_absent(
        headers,
        header::HeaderName::from_static("permissions-policy"),
        "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    );
    set_if_absent(
        headers,
        header::HeaderName::from_static("x-permitted-cross-domain-policies"),
        "none",
    );
    resp
}

fn set_if_absent(
    headers: &mut axum::http::HeaderMap,
    name: header::HeaderName,
    value: &'static str,
) {
    if !headers.contains_key(&name) {
        if let Ok(v) = HeaderValue::from_str(value) {
            headers.insert(name, v);
        }
    }
}
