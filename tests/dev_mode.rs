//! Integration tests for `--dev` mode: every request is mapped onto the
//! passwordless `local` owner account with no credentials at all, and the
//! database lives in process memory only.

#![cfg(test)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers, AppState,
};

fn base_config(db_url: &str) -> Config {
    Config {
        host: "127.0.0.1".into(),
        port: 7878,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url: db_url.to_string(),
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: devinorium::config::default_home_dir().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        }),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        dev_mode: false,
    }
}

async fn make_app(dev_mode: bool) -> (axum::Router, db::Db) {
    // `sqlite::memory:` exercises the same in-memory database path `--dev`
    // uses; the non-dev variant uses a temp file so session lookup is real.
    let db_url = if dev_mode {
        "sqlite::memory:".to_string()
    } else {
        let dir = tempfile::tempdir().expect("tempdir").keep();
        format!("sqlite:{}?mode=rwc", dir.join("test.db").display())
    };
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run_local(&database)
        .await
        .expect("local bootstrap");

    sqlx::query("UPDATE users SET provider_command = ''")
        .execute(database.pool())
        .await
        .unwrap();

    let mut cfg = base_config(&db_url);
    cfg.dev_mode = dev_mode;

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
    };
    (devinorium::build_app(state), database)
}

async fn me_status(app: &axum::Router) -> (StatusCode, String) {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, String::from_utf8(bytes.to_vec()).unwrap())
}

#[tokio::test]
async fn dev_mode_me_returns_local_user_without_credentials() {
    let (app, _db) = make_app(true).await;
    let (status, body) = me_status(&app).await;
    assert_eq!(status, StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["username"], "local");
    assert_eq!(json["is_owner"], true);
}

#[tokio::test]
async fn dev_mode_write_request_needs_no_credentials() {
    let (app, _db) = make_app(true).await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/thread-groups")
                .header("content-type", "application/json")
                // Same-origin headers so the CSRF check passes.
                .header("host", "localhost")
                .header("origin", "http://localhost")
                .body(Body::from(r#"{"name":"dev group"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn without_dev_mode_requests_still_require_auth() {
    let (app, _db) = make_app(false).await;
    let (status, _) = me_status(&app).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn dev_mode_rejects_non_loopback_host_header() {
    // DNS rebinding makes a remote page send Host: attacker.com to the
    // loopback socket; dev mode refuses it before any route runs.
    let (app, _db) = make_app(true).await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("host", "attacker.example.com")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("host", "localhost:42963")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn in_memory_db_persists_for_the_process() {
    // The pooled connection must be reused: data written through one
    // acquire has to be visible through the next.
    let database = db::Db::connect("sqlite::memory:")
        .await
        .expect("db connect");
    // Pin the invariant: one permanent connection, never recycled. A second
    // or recycled connection would be a fresh empty database.
    assert_eq!(database.pool().options().get_max_connections(), 1);
    assert_eq!(database.pool().options().get_min_connections(), 1);
    auth::bootstrap::run_local(&database)
        .await
        .expect("bootstrap");
    assert_eq!(database.count_users().await.unwrap(), 1);
    let user = database
        .get_user_by_username(auth::bootstrap::LOCAL_USERNAME)
        .await
        .unwrap()
        .expect("local user");
    assert!(user.is_owner);
}

#[tokio::test]
async fn in_memory_dbs_do_not_share_state() {
    // Each `sqlite::memory:` pool is its own database; nothing on disk and
    // nothing shared between instances.
    let a = db::Db::connect("sqlite::memory:").await.unwrap();
    let b = db::Db::connect("sqlite::memory:").await.unwrap();
    a.create_user(db::NewUser {
        username: "only-in-a".into(),
        password_hash: "!local-mode".into(),
        is_owner: false,
    })
    .await
    .unwrap();
    assert!(b.get_user_by_username("only-in-a").await.unwrap().is_none());
}

#[test]
fn apply_dev_mode_sets_random_port_and_memory_db() {
    let mut cfg = base_config("sqlite:data/devinorium.db?mode=rwc");
    cfg.apply_dev_mode().unwrap();
    assert_eq!(cfg.port, 0);
    assert_eq!(cfg.db_url, "sqlite::memory:");
    assert!(cfg.dev_mode);
}

#[test]
fn apply_dev_mode_rejects_non_loopback_host() {
    let mut cfg = base_config("sqlite::memory:");
    cfg.host = "0.0.0.0".into();
    assert!(cfg.apply_dev_mode().is_err());
    assert!(!cfg.dev_mode);
}
