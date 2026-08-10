//! Static asset serving — embeds the frontend at compile time so the binary
//! is fully self-contained, and provides an SPA fallback to index.html.

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use axum::Router;

use crate::AppState;

// Embed the frontend files at compile time.
const INDEX_HTML: &str = include_str!("../static/index.html");
const STYLES_CSS: &str = include_str!("../static/styles.css");
const APP_JS: &str = include_str!("../static/app.js");

/// A router that serves the embedded static assets.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/static/styles.css", any(|| async { serve(STYLES_CSS, "text/css; charset=utf-8") }))
        .route("/static/app.js", any(|| async { serve(APP_JS, "application/javascript; charset=utf-8") }))
        .route("/", any(|| async { serve(INDEX_HTML, "text/html; charset=utf-8") }))
        .fallback(spa_fallback)
}

async fn spa_fallback(uri: Uri) -> Response {
    // Any non-API GET that isn't a known static file falls back to index.html
    // (SPA routing). API paths that didn't match return 404.
    let path = uri.path();
    if path.starts_with("/api/") {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }
    serve(INDEX_HTML, "text/html; charset=utf-8")
}

fn serve(content: &'static str, mime: &str) -> Response {
    let mut resp = Response::new(Body::from(content));
    *resp.status_mut() = StatusCode::OK;
    resp.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_str(mime).unwrap());
    resp.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache"),
    );
    resp
}
