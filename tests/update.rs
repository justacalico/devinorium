//! Integration tests for the server self-update endpoints: auth and the
//! environment guards (dev mode, bundled local mode) run before any
//! download happens, so they are safe to exercise end-to-end. The happy
//! path (download, checksum, binary swap) is covered by unit tests in
//! `src/update.rs` — running it here would replace the test binary.

#![cfg(test)]

use std::future::IntoFuture;
use std::sync::Arc;

use axum::body::{to_bytes, Body};
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

const LOCAL_TOKEN: &str = "test-local-token-0123456789abcdef";

/// Serializes tests that point the update service at a mock releases API
/// via `DEVINORIUM_UPDATE_API_URL`.
static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn make_app(dev_mode: bool, local_token: Option<&str>) -> (Router, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("update.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    auth::bootstrap::run_local(&database)
        .await
        .expect("local bootstrap");

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: dir.join("files"),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: local_token.map(str::to_string),
        tailscale_bin: "tailscale".into(),
        dev_mode,
    };

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .expect("provider");

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
    };
    (devinorium::build_app(state), database)
}

fn authed(method: &str, uri: &str, cookie: &str, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::HOST, "localhost")
        .header(header::ORIGIN, "http://localhost")
        .header("cookie", cookie);
    if !body.is_empty() {
        b = b.header("content-type", "application/json");
    }
    b.body(Body::from(body.to_string())).unwrap()
}

fn bearer(method: &str, uri: &str, token: &str, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::HOST, "localhost")
        .header(header::ORIGIN, "http://localhost")
        .header("authorization", format!("Bearer {token}"));
    if !body.is_empty() {
        b = b.header("content-type", "application/json");
    }
    b.body(Body::from(body.to_string())).unwrap()
}

async fn login(app: &Router) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sc = resp.headers().get("set-cookie").unwrap().to_str().unwrap();
    sc.split(';').next().unwrap().to_string()
}

async fn create_user(app: &Router, owner_cookie: &str, username: &str) -> String {
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/users",
            owner_cookie,
            &format!(r#"{{"username":"{username}","password":"usersecret123"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"username":"{username}","password":"usersecret123"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sc = resp.headers().get("set-cookie").unwrap().to_str().unwrap();
    sc.split(';').next().unwrap().to_string()
}

async fn body_str(b: Body) -> String {
    String::from_utf8(to_bytes(b, 1024 * 1024).await.unwrap().to_vec()).unwrap()
}

/// Serve a canned GitLab releases response from a loopback mock.
async fn mock_releases_api(body: serde_json::Value) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = axum::Router::new().route(
        "/releases",
        axum::routing::get(move || {
            let body = body.clone();
            async move { axum::Json(body) }
        }),
    );
    tokio::spawn(axum::serve(listener, app).into_future());
    format!("http://127.0.0.1:{port}")
}

#[tokio::test]
async fn update_endpoints_require_auth() {
    let (app, _db) = make_app(false, None).await;
    for (method, uri) in [
        ("GET", "/api/server/update/check"),
        ("POST", "/api/server/update/apply"),
    ] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header(header::HOST, "localhost")
                    .header(header::ORIGIN, "http://localhost")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "{method} {uri}");
    }
}

#[tokio::test]
async fn update_endpoints_are_owner_only() {
    let (app, _db) = make_app(false, None).await;
    let owner_cookie = login(&app).await;
    let cookie = create_user(&app, &owner_cookie, "alice").await;

    for (method, uri) in [
        ("GET", "/api/server/update/check"),
        ("POST", "/api/server/update/apply"),
    ] {
        let resp = app
            .clone()
            .oneshot(authed(method, uri, &cookie, "{}"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN, "{method} {uri}");
    }
}

#[tokio::test]
async fn apply_is_rejected_in_dev_mode() {
    let (app, _db) = make_app(true, None).await;
    // Dev mode maps every request onto the local owner; the dev-mode guard
    // rejects before any download starts.
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/server/update/apply")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("development instances"));
}

#[tokio::test]
async fn apply_is_rejected_in_bundled_local_mode() {
    let (app, _db) = make_app(false, Some(LOCAL_TOKEN)).await;
    let resp = app
        .oneshot(bearer(
            "POST",
            "/api/server/update/apply",
            LOCAL_TOKEN,
            "{}",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("bundled server"));
}

#[tokio::test]
async fn check_reports_not_updatable_in_bundled_local_mode() {
    let (app, _db) = make_app(false, Some(LOCAL_TOKEN)).await;
    // No releases API is configured; a bundled instance must not hit the
    // network at all, so this answers purely from the environment.
    let resp = app
        .oneshot(bearer("GET", "/api/server/update/check", LOCAL_TOKEN, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert!(!body["updatable"].as_bool().unwrap());
    assert_eq!(body["reason"].as_str().unwrap(), "local_mode");
    assert!(body["latest_tag"].is_null());
}

#[tokio::test]
async fn check_reports_release_and_apply_reports_no_update() {
    let _guard = ENV_LOCK.lock().await;
    // A mock releases API whose newest tag is older than the running build.
    let base = mock_releases_api(serde_json::json!([
        {"tag_name": "nightly", "assets": {"links": []}},
        {"tag_name": "v0.0.1", "assets": {"links": []}},
    ]))
    .await;
    std::env::set_var("DEVINORIUM_UPDATE_API_URL", &base);

    let (app, _db) = make_app(false, None).await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/server/update/check", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(
        body["current_version"].as_str().unwrap(),
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(body["latest_tag"].as_str().unwrap(), "v0.0.1");
    assert!(!body["update_available"].as_bool().unwrap());
    assert_eq!(
        body["updatable"].as_bool().unwrap(),
        devinorium::update::platform_asset_suffix().is_some()
    );

    // The owner can POST apply; with nothing newer it is a conflict, and
    // no binary is touched.
    let resp = app
        .oneshot(authed("POST", "/api/server/update/apply", &cookie, "{}"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    assert!(body_str(resp.into_body()).await.contains("no update"));
}
