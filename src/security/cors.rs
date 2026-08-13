//! Cross-Origin Resource Sharing (CORS) support for native clients.
//!
//! The web frontend is served same-origin, so CORS is disabled by default.
//! When `DEVINORIUM_ALLOWED_ORIGIN` is set, a strict CORS layer is applied
//! to allow cross-origin requests from that single origin only.

use std::time::Duration;

use axum::http::{header, HeaderValue, Method};
use tower_http::cors::CorsLayer;

/// Build a CORS layer for the configured allowed origin, if any.
///
/// The layer allows credentials, the common HTTP methods, and the
/// `Content-Type` and `Authorization` headers required by the native client.
pub fn build_cors_layer(allowed_origin: &Option<String>) -> Option<CorsLayer> {
    let origin = allowed_origin.as_ref()?;
    if origin.is_empty() {
        return None;
    }
    let origin = origin.trim();
    let parsed = match origin.parse::<HeaderValue>() {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("DEVINORIUM_ALLOWED_ORIGIN is not a valid header value: {e}");
            return None;
        }
    };

    let methods = [
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
    ];
    let headers = [header::CONTENT_TYPE, header::AUTHORIZATION];

    Some(
        CorsLayer::new()
            .allow_origin(tower_http::cors::AllowOrigin::list([parsed]))
            .allow_credentials(true)
            .allow_methods(methods)
            .allow_headers(headers)
            .max_age(Duration::from_secs(86400)),
    )
}
