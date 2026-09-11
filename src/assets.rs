//! Static asset serving — embeds the Flutter web frontend at compile time so
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

// Embed the entire Flutter web build output at compile time.
// The frontend must be built first with ./scripts/build-flutter.sh, which
// writes the Flutter web bundle into frontend/dist/.
static FRONTEND_DIST: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/frontend/dist");

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
    let mut resp = Response::new(Body::from(file.contents()));
    *resp.status_mut() = StatusCode::OK;
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&content_type_for(path)).unwrap(),
    );
    if let Ok(val) = HeaderValue::from_str(cache_control_for(path)) {
        resp.headers_mut().insert(header::CACHE_CONTROL, val);
    }
    Some(resp)
}

fn content_type_for(path: &str) -> String {
    // mime_guess has no application/manifest+json mapping; Safari accepts a
    // plain JSON type but the registered type is more correct.
    if path == "manifest.json" {
        "application/manifest+json".to_string()
    } else {
        mime_guess::from_path(path)
            .first_or_octet_stream()
            .to_string()
    }
}

fn cache_control_for(path: &str) -> &'static str {
    // index.html is the SPA entry point and must revalidate on every load.
    if path == "index.html" {
        return "no-cache";
    }
    // These filenames are stable across builds rather than content-hashed, so
    // an immutable year-long cache would serve stale copies after an upgrade.
    // iOS in particular caches home-screen icons and the manifest at install.
    if path == "manifest.json"
        || path == "version.json"
        || path == "favicon.png"
        || path == "flutter_service_worker.js"
        || path.starts_with("icons/")
    {
        return "public, max-age=3600";
    }
    "public, max-age=31536000, immutable"
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_html_declares_ios_pwa_support() {
        let file = FRONTEND_DIST
            .get_file("index.html")
            .expect("index.html must be embedded");
        let html = std::str::from_utf8(file.contents()).unwrap();
        assert!(html.contains(r#"<link rel="manifest" href="manifest.json">"#));
        assert!(html.contains(r#"name="apple-mobile-web-app-capable""#));
        assert!(html.contains(r#"rel="apple-touch-icon""#));
        assert!(html.contains(r#"rel="apple-touch-startup-image""#));
    }

    #[test]
    fn manifest_json_uses_pwa_content_type() {
        assert_eq!(content_type_for("manifest.json"), "application/manifest+json");
        // frontend/dist/manifest.json only exists after scripts/build-flutter.sh
        // has run, so skip rather than fail on a bare checkout.
        let Some(resp) = try_serve_file("manifest.json") else {
            return;
        };
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers()[header::CONTENT_TYPE],
            "application/manifest+json"
        );
    }

    #[test]
    fn pwa_assets_use_short_lived_cache() {
        assert_eq!(cache_control_for("index.html"), "no-cache");
        for path in [
            "manifest.json",
            "version.json",
            "favicon.png",
            "flutter_service_worker.js",
            "icons/apple-touch-icon.png",
            "icons/splash/apple-splash-1125x2436.png",
        ] {
            assert_eq!(cache_control_for(path), "public, max-age=3600", "{path}");
        }
        assert_eq!(
            cache_control_for("main.dart.wasm"),
            "public, max-age=31536000, immutable"
        );
    }

    #[test]
    fn touch_icons_serve_as_png() {
        let Some(resp) = try_serve_file("icons/apple-touch-icon.png") else {
            return;
        };
        assert_eq!(resp.headers()[header::CONTENT_TYPE], "image/png");
    }
}
