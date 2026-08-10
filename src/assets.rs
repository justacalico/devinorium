//! Static asset serving — embeds the Dioxus WASM frontend at compile time so
//! the binary is fully self-contained, and provides an SPA fallback to
//! index.html.

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::any;
use axum::Router;
use include_dir::{include_dir, Dir};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use crate::AppState;

// Embed the entire Dioxus build output at compile time.
// The frontend must be built first with `dx build --release` (from the frontend/ directory).
static FRONTEND_DIST: Dir<'static> =
    include_dir!("$CARGO_MANIFEST_DIR/frontend/dist");

/// A router that serves the embedded frontend assets.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", any(|| async { serve_file("index.html") }))
        .fallback(spa_fallback)
}

async fn spa_fallback(uri: Uri) -> Response {
    let path = uri.path();
    if path.starts_with("/api/") {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }
    // Try to serve the exact file from the embedded directory.
    let clean_path = path.trim_start_matches('/');
    if !clean_path.is_empty() {
        if let Some(resp) = try_serve_file(clean_path) {
            return resp;
        }
    }
    // Fallback to index.html for SPA routing.
    serve_file("index.html")
}

fn try_serve_file(path: &str) -> Option<Response> {
    let file = FRONTEND_DIST.get_file(path)?;
    let mime = mime_guess::from_path(path).first_or_octet_stream();
    let mut resp = Response::new(Body::from(file.contents()));
    *resp.status_mut() = StatusCode::OK;
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(mime.as_ref()).unwrap(),
    );
    // Hashed assets can be cached aggressively; index.html should not.
    let cache = if path == "index.html" { "no-cache" } else { "public, max-age=31536000, immutable" };
    if let Ok(val) = HeaderValue::from_str(cache) {
        resp.headers_mut().insert(header::CACHE_CONTROL, val);
    }
    Some(resp)
}

fn serve_file(path: &str) -> Response {
    try_serve_file(path).unwrap_or_else(|| {
        let mut resp = Response::new(Body::from("not found"));
        *resp.status_mut() = StatusCode::NOT_FOUND;
        resp
    })
}

// Suppress unused warning — kept for potential future use.
#[allow(dead_code)]
fn _encode_uri(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}
