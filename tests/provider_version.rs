//! Integration tests for the provider version endpoint.

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

async fn make_app() -> (Router, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("version.db").display());
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
        home_dir: dir.join("files"),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        tailscale_serve: false,
        tailscale_serve_port: 443,
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
    };
    (devinorium::build_app(state), database)
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

async fn set_provider_command(db: &db::Db, command: &str) {
    sqlx::query("UPDATE users SET provider_command = ? WHERE username = 'owner'")
        .bind(command)
        .execute(db.pool())
        .await
        .unwrap();
}

async fn get_version(app: Router, cookie: &str) -> serde_json::Value {
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/providers/version")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&body).unwrap()
}

#[tokio::test]
async fn provider_version_requires_auth() {
    let (app, _db) = make_app().await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/providers/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[cfg(unix)]
#[tokio::test]
async fn provider_version_reports_installed_binary() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("fake-devin");
    std::fs::write(&script, "#!/bin/sh\necho 'devin 9.9.9 (test)'\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    set_provider_command(&db, script.to_str().unwrap()).await;

    let json = get_version(app, &cookie).await;
    assert_eq!(json["provider_id"].as_str().unwrap(), "devin-cli");
    assert_eq!(json["provider_name"].as_str().unwrap(), "Devin CLI");
    assert_eq!(json["installed_version"].as_str().unwrap(), "9.9.9");
    // `latest_version` depends on reaching the release manifest; in a
    // sandboxed environment it may legitimately be null.
    assert!(json.get("latest_version").is_some());
    assert!(json["update_available"].is_boolean());
}

#[tokio::test]
async fn provider_version_handles_missing_binary() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    set_provider_command(&db, "/nonexistent/devin-cli-binary").await;

    let json = get_version(app, &cookie).await;
    assert_eq!(json["provider_id"].as_str().unwrap(), "devin-cli");
    assert_eq!(json["installed_version"], serde_json::Value::Null);
    // Without an installed version there can never be an update.
    assert_eq!(json["update_available"], serde_json::Value::Bool(false));
}
