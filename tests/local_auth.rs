//! Integration tests for bundled local mode: `DEVINORIUM_LOCAL_TOKEN` maps a
//! fixed bearer token onto the auto-created `local` owner account, while
//! regular session logins keep working.

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

const LOCAL_TOKEN: &str = "test-local-token-0123456789abcdef";

async fn make_app(local_token: Option<&str>) -> (axum::Router, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    if local_token.is_some() {
        auth::bootstrap::run_local(&database)
            .await
            .expect("local bootstrap");
    }

    sqlx::query("UPDATE users SET provider_command = ''")
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
        allowed_origin: None,
        local_token: local_token.map(str::to_string),
        dev_mode: false,
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
    };
    (devinorium::build_app(state), database)
}

async fn me_status(app: &axum::Router, bearer: Option<&str>) -> (StatusCode, String) {
    let mut builder = Request::builder().uri("/api/auth/me");
    if let Some(token) = bearer {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    let resp = app
        .clone()
        .oneshot(builder.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, String::from_utf8(bytes.to_vec()).unwrap())
}

#[tokio::test]
async fn local_token_grants_local_account() {
    let (app, _db) = make_app(Some(LOCAL_TOKEN)).await;
    let (status, body) = me_status(&app, Some(LOCAL_TOKEN)).await;
    assert_eq!(status, StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["username"], "local");
    assert_eq!(json["is_owner"], true);
}

#[tokio::test]
async fn requests_without_or_with_wrong_token_are_rejected() {
    let (app, _db) = make_app(Some(LOCAL_TOKEN)).await;

    let (status, _) = me_status(&app, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, _) = me_status(&app, Some("wrong-token")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn password_login_still_works_in_local_mode() {
    let (app, _db) = make_app(Some(LOCAL_TOKEN)).await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                // Bearer auth exempts the request from the CSRF origin check.
                .header("authorization", format!("Bearer {LOCAL_TOKEN}"))
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let token = json["token"].as_str().unwrap().to_string();

    let (status, body) = me_status(&app, Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["username"], "owner");
}

#[tokio::test]
async fn local_account_cannot_be_logged_into_with_a_password() {
    let (app, _db) = make_app(Some(LOCAL_TOKEN)).await;

    // The local account's password is random, so no credential works.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {LOCAL_TOKEN}"))
                .body(Body::from(r#"{"username":"local","password":"local"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn run_local_does_not_promote_a_foreign_local_account() {
    // A `local` user created through normal registration (real password hash)
    // is not ours — re-running local bootstrap must not flip it to owner.
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    database
        .create_user(db::NewUser {
            username: "local".into(),
            password_hash: auth::password::hash("somepassword").unwrap(),
            is_owner: false,
        })
        .await
        .unwrap();

    auth::bootstrap::run_local(&database).await.unwrap();

    let user = database
        .get_user_by_username("local")
        .await
        .unwrap()
        .unwrap();
    assert!(!user.is_owner, "foreign local account must stay non-owner");
}

#[tokio::test]
async fn run_local_restores_owner_on_its_own_sentinel_account() {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    database
        .create_user(db::NewUser {
            username: "local".into(),
            password_hash: "!local-mode".into(),
            is_owner: false,
        })
        .await
        .unwrap();

    auth::bootstrap::run_local(&database).await.unwrap();

    let user = database
        .get_user_by_username("local")
        .await
        .unwrap()
        .unwrap();
    assert!(user.is_owner);
}

#[tokio::test]
async fn cookie_session_survives_an_unrelated_bearer_header() {
    // Proxies may inject their own Authorization header; a bogus bearer must
    // not shadow a valid session cookie.
    let (app, _db) = make_app(None).await;

    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .header("host", "localhost")
                .header("origin", "http://localhost")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(login.status(), StatusCode::OK);
    let cookie = login
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", cookie)
                .header("authorization", "Bearer unrelated-proxy-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn run_local_is_idempotent() {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");

    auth::bootstrap::run_local(&database).await.unwrap();
    auth::bootstrap::run_local(&database).await.unwrap();

    let user = database
        .get_user_by_username(auth::bootstrap::LOCAL_USERNAME)
        .await
        .unwrap()
        .expect("local user");
    assert!(user.is_owner);
    assert_eq!(database.count_users().await.unwrap(), 1);
}

#[tokio::test]
async fn run_local_keeps_existing_accounts() {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");

    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .unwrap();
    auth::bootstrap::run_local(&database).await.unwrap();

    assert_eq!(database.count_users().await.unwrap(), 2);
}

#[tokio::test]
async fn disabled_local_account_still_authenticates_via_local_token() {
    let (app, db) = make_app(Some(LOCAL_TOKEN)).await;
    let local = db
        .get_user_by_username(auth::bootstrap::LOCAL_USERNAME)
        .await
        .unwrap()
        .unwrap();
    db.set_user_disabled(local.id, true).await.unwrap();

    // The desktop app holds the only copy of the token, so disabling the
    // account must not lock the app out of its own bundled server.
    let (status, _) = me_status(&app, Some(LOCAL_TOKEN)).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn without_local_token_bearer_is_a_normal_session_lookup() {
    let (app, _db) = make_app(None).await;
    let (status, _) = me_status(&app, Some(LOCAL_TOKEN)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}
