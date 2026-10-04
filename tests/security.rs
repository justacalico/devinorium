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

use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers, AppState,
};

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
        home_dir: devinorium::config::default_home_dir().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        }),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
        satellite: false,
        node_name: String::new(),
    };

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .unwrap();

    let state = AppState {
        config: Arc::new(cfg.clone()),
        db: database.clone(),
        provider: Arc::from(provider),
        provider_status: devinorium::providers::ProviderStatusCache::new(),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        pending_ask_requests: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        terminal_manager: devinorium::terminal::manager::TerminalManager::new(
            std::time::Duration::from_secs(30 * 60),
            std::time::Duration::from_secs(60),
        ),
        git: Arc::new(GitService::new()),
        git_remote: Arc::new(GitRemoteService::new(cfg.home_dir.clone())),
        tailscale: devinorium::tailscale::Tailscale::new("tailscale"),
        machine_grants: devinorium::machine_grants::MachineGrants::new(),
        push: devinorium::push::PushService::disabled(),
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
        http_client: reqwest::Client::new(),
        remote_terminals: std::sync::Arc::new(std::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        rate_limiter: devinorium::security::RateLimiter::new(500, 2.0),
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
        "expected rate limiting to kick in: {statuses:?}"
    );
}

#[tokio::test]
async fn rate_limit_probes_with_bogus_credentials_are_charged() {
    let (app, _db) = make_app(None).await;
    // A forged Cookie header must not launder the probe into a free read:
    // the auth middleware debits the probe bucket when the credential fails.
    for cookie in ["x=y", "devinorium_session=forged"] {
        let mut saw_limited = false;
        for _ in 0..25 {
            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("GET")
                        .uri("/api/threads")
                        .header(header::COOKIE, cookie)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            let status = resp.status();
            assert!(
                status == StatusCode::UNAUTHORIZED || status == StatusCode::TOO_MANY_REQUESTS,
                "probe must fail, got {status}"
            );
            if status == StatusCode::TOO_MANY_REQUESTS {
                saw_limited = true;
                break;
            }
        }
        assert!(saw_limited, "probes with `{cookie}` never hit 429");
    }
}

#[tokio::test]
async fn rate_limit_machine_token_failures_are_charged() {
    let (app, _db) = make_app(None).await;
    // Public route with its own token auth: a bogus Bearer must still pay
    // the probe rate instead of riding the cheap write classification.
    let mut saw_limited = false;
    for _ in 0..25 {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/machine-control/1/screenshot")
                    .header(header::AUTHORIZATION, "Bearer bogus")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = resp.status();
        assert!(
            status == StatusCode::UNAUTHORIZED || status == StatusCode::TOO_MANY_REQUESTS,
            "probe must fail, got {status}"
        );
        if status == StatusCode::TOO_MANY_REQUESTS {
            saw_limited = true;
            break;
        }
    }
    assert!(saw_limited, "machine-token probes never hit 429");
}

#[tokio::test]
async fn rate_limit_federation_register_failures_are_charged() {
    let (app, _db) = make_app(None).await;
    let mut saw_limited = false;
    for _ in 0..25 {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/federation/nodes/pair")
                    .header(header::AUTHORIZATION, "Bearer bogus")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = resp.status();
        assert!(
            status == StatusCode::UNAUTHORIZED || status == StatusCode::TOO_MANY_REQUESTS,
            "probe must fail, got {status}"
        );
        if status == StatusCode::TOO_MANY_REQUESTS {
            saw_limited = true;
            break;
        }
    }
    assert!(saw_limited, "federation-token probes never hit 429");
}

async fn bad_login(app: Router, username: &str) -> StatusCode {
    app.oneshot(
        Request::builder()
            .method("POST")
            .uri("/api/auth/login")
            .header(header::HOST, "localhost:7878")
            .header(header::ORIGIN, "http://localhost:7878")
            .header("content-type", "application/json")
            .body(Body::from(format!(
                r#"{{"username":"{username}","password":"wrong-password"}}"#
            )))
            .unwrap(),
    )
    .await
    .unwrap()
    .status()
}

#[tokio::test]
async fn rate_limit_login_throttles_per_username() {
    let (app, _db) = make_app(None).await;
    // 20 attempts at one username drain the per-username bucket; the next
    // attempt for the same name is 429 even though the IP bucket has room.
    let mut last = StatusCode::OK;
    for _ in 0..21 {
        last = bad_login(app.clone(), "owner").await;
    }
    assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
    // A different username still reaches the verifier (401, not 429).
    assert_eq!(
        bad_login(app, "someone-else").await,
        StatusCode::UNAUTHORIZED
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
        home_dir: devinorium::config::default_home_dir().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        }),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 64,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
        satellite: false,
        node_name: String::new(),
    };
    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .unwrap();
    let state = AppState {
        config: Arc::new(cfg.clone()),
        db: database,
        provider: Arc::from(provider),
        provider_status: devinorium::providers::ProviderStatusCache::new(),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        pending_ask_requests: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        terminal_manager: devinorium::terminal::manager::TerminalManager::new(
            std::time::Duration::from_secs(30 * 60),
            std::time::Duration::from_secs(60),
        ),
        git: Arc::new(GitService::new()),
        git_remote: Arc::new(GitRemoteService::new(cfg.home_dir.clone())),
        tailscale: devinorium::tailscale::Tailscale::new("tailscale"),
        machine_grants: devinorium::machine_grants::MachineGrants::new(),
        push: devinorium::push::PushService::disabled(),
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
        http_client: reqwest::Client::new(),
        remote_terminals: std::sync::Arc::new(std::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        rate_limiter: devinorium::security::RateLimiter::new(500, 2.0),
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

async fn login_with_origin(app: &Router, username: &str, password: &str, origin: &str) -> String {
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
    let allow_methods = h
        .get("access-control-allow-methods")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(allow_methods.contains("GET"), "methods: {allow_methods}");
    let allow_headers = h
        .get("access-control-allow-headers")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(
        allow_headers.to_lowercase().contains("authorization"),
        "headers: {allow_headers}"
    );
}

#[tokio::test]
async fn bearer_token_bypasses_csrf_with_cors() {
    let (app, _db) = make_app(Some("https://devinorium.example".into())).await;
    let cookie = login_with_origin(
        &app,
        "owner",
        "supersecret123",
        "https://devinorium.example",
    )
    .await;
    let token = token_from_cookie(&cookie);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/totp/disable")
                .header(header::ORIGIN, "https://devinorium.example")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"password":"supersecret123"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
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
                .uri("/api/auth/totp/disable")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"password":"supersecret123"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}
