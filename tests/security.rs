//! Integration tests for the security middleware stack: security headers,
//! CSRF origin enforcement, rate limiting, and body size limits.
//!
//! These use the real `build_app` so they exercise the exact production
//! middleware ordering.

#![cfg(test)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use tower::ServiceExt;

use devinorium::{auth, config::Config, db, git::GitService, providers, AppState};

async fn make_app(allowed_origin: Option<String>) -> (Router, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("sec.db").display());
    let database = db::Db::connect(&db_url).await.unwrap();
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .unwrap();

    sqlx::query("UPDATE users SET provider_command = '' WHERE username = 'owner'")
        .execute(database.pool())
        .await
        .unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url: db_url.clone(),
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: devinorium::config::default_home_dir()
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin,
    };

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .unwrap();

    let state = AppState {
        config: Arc::new(cfg),
        db: database.clone(),
        provider: Arc::from(provider),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        git: Arc::new(GitService::new()),
    };
    (devinorium::build_app(state), database)
}

#[tokio::test]
async fn security_headers_present() {
    let (app, _db) = make_app(None).await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/healthz")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let h = resp.headers();
    assert_eq!(h.get(header::X_CONTENT_TYPE_OPTIONS).unwrap(), "nosniff");
    assert_eq!(h.get(header::X_FRAME_OPTIONS).unwrap(), "DENY");
    assert_eq!(h.get(header::REFERRER_POLICY).unwrap(), "no-referrer");
    assert!(h
        .get(header::CONTENT_SECURITY_POLICY)
        .unwrap()
        .to_str()
        .unwrap()
        .contains("default-src 'self'"));
    assert!(h
        .get("permissions-policy")
        .unwrap()
        .to_str()
        .unwrap()
        .contains("camera=()"));
}

#[tokio::test]
async fn csrf_rejects_post_without_origin() {
    let (app, _db) = make_app(None).await;
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost:7878")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"x","password":"y"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn csrf_allows_post_with_matching_origin() {
    let (app, _db) = make_app(None).await;
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost:7878")
                .header(header::ORIGIN, "http://localhost:7878")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    // Should pass CSRF and reach the handler (login succeeds).
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn csrf_rejects_cross_origin_post() {
    let (app, _db) = make_app(None).await;
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost:7878")
                .header(header::ORIGIN, "http://evil.com")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn csrf_explicit_allowed_origin_enforced() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    // Wrong origin -> rejected.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::ORIGIN, "https://evil.com")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Correct origin -> allowed.
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::ORIGIN, "https://devinorium.example")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn rate_limit_blocks_after_burst() {
    let (app, _db) = make_app(None).await;
    // Weighted limiter: login costs 20 tokens, capacity 500.
    // 25 logins = 500 tokens → 26th should be 429.
    // Fire 30 to be sure.
    let mut statuses = Vec::new();
    for _ in 0..30 {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/login")
                    .header(header::HOST, "localhost:7878")
                    .header(header::ORIGIN, "http://localhost:7878")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"username":"owner","password":"wrong"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        statuses.push(resp.status());
    }
    // First several should be 401 (bad password) or 403; after 10, 429.
    let too_many = statuses
        .iter()
        .filter(|s| **s == StatusCode::TOO_MANY_REQUESTS)
        .count();
    assert!(
        too_many >= 1,
        "expected rate limiting to kick in: {:?}",
        statuses
    );
}

#[tokio::test]
async fn body_size_limit_rejects_oversized() {
    // Build an app with a tiny body limit.
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("tiny.db").display());
    let database = db::Db::connect(&db_url).await.unwrap();
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .unwrap();
    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: devinorium::config::default_home_dir()
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 64,
        secure_cookie: false,
        allowed_origin: None,
    };
    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .unwrap();
    let state = AppState {
        config: Arc::new(cfg),
        db: database,
        provider: Arc::from(provider),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        git: Arc::new(GitService::new()),
    };
    let app = devinorium::build_app(state);

    let big = "x".repeat(10_000);
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost:7878")
                .header(header::ORIGIN, "http://localhost:7878")
                .header("content-type", "application/json")
                .body(Body::from(big))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

async fn login_with_origin(
    app: &Router,
    username: &str,
    password: &str,
    origin: &str,
) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost:7878")
                .header(header::ORIGIN, origin)
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"username":"{username}","password":"{password}"}}"#,
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    resp.headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string()
}

fn token_from_cookie(cookie: &str) -> &str {
    cookie.strip_prefix("devinorium_session=").unwrap()
}

#[tokio::test]
async fn cors_headers_on_allowed_origin() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/healthz")
                .header(header::ORIGIN, "https://devinorium.example")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let h = resp.headers();
    assert_eq!(
        h.get("access-control-allow-origin").unwrap(),
        "https://devinorium.example"
    );
    assert_eq!(h.get("access-control-allow-credentials").unwrap(), "true");
}

#[tokio::test]
async fn cors_blocks_disallowed_origin() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/healthz")
                .header(header::ORIGIN, "https://evil.com")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(resp.headers().get("access-control-allow-origin").is_none());
}

#[tokio::test]
async fn cors_preflight_for_api() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    let resp = app
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/threads")
                .header(header::ORIGIN, "https://devinorium.example")
                .header(header::ACCESS_CONTROL_REQUEST_METHOD, "GET")
                .header(header::ACCESS_CONTROL_REQUEST_HEADERS, "authorization")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(resp.status().is_success());
    let h = resp.headers();
    assert_eq!(
        h.get("access-control-allow-origin").unwrap(),
        "https://devinorium.example"
    );
    let allow_methods = h.get("access-control-allow-methods").unwrap().to_str().unwrap();
    assert!(allow_methods.contains("GET"), "methods: {allow_methods}");
    let allow_headers = h.get("access-control-allow-headers").unwrap().to_str().unwrap();
    assert!(
        allow_headers.to_lowercase().contains("authorization"),
        "headers: {allow_headers}"
    );
}

#[tokio::test]
async fn bearer_token_bypasses_csrf_with_cors() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    let cookie = login_with_origin(&app, "owner", "supersecret123", "https://devinorium.example").await;
    let token = token_from_cookie(&cookie);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/devices/revoke")
                .header(header::ORIGIN, "https://devinorium.example")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"device_id":"does-not-exist"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        resp.headers().get("access-control-allow-origin").unwrap(),
        "https://devinorium.example"
    );
}

#[tokio::test]
async fn bearer_token_bypasses_csrf_without_origin() {
    let (app, _db) = make_app(None).await;
    let cookie = login_with_origin(&app, "owner", "supersecret123", "http://localhost:7878").await;
    let token = token_from_cookie(&cookie);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/devices/revoke")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"device_id":"does-not-exist"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
