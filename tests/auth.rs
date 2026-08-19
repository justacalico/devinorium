//! Integration tests for the auth system: bootstrap, login, `me`, owner
//! account management, TOTP setup/verify, and role enforcement.
//!
//! These spin up a real axum app against a temp SQLite db.

#![cfg(test)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, Router};
use tower::ServiceExt;

use devinorium::{auth, config::Config, db, git::{GitRemoteService, GitService}, providers, AppState};

async fn make_app(bootstrap_user: &str, bootstrap_pw: &str) -> (AppState, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, bootstrap_user, bootstrap_pw)
        .await
        .expect("bootstrap");

    sqlx::query("UPDATE users SET provider_command = '' WHERE username = ?")
        .bind(bootstrap_user)
        .execute(database.pool())
        .await
        .unwrap();

    let mut cfg = Config::from_env().unwrap_or_else(|_| Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url: db_url.clone(),
        bootstrap_username: bootstrap_user.into(),
        bootstrap_password: bootstrap_pw.into(),
        home_dir: devinorium::config::default_home_dir().unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        }),
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
    });
    cfg.db_url = db_url;
    cfg.bootstrap_username = bootstrap_user.into();
    cfg.bootstrap_password = bootstrap_pw.into();

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
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        pending_ask_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        thread_runner: devinorium::thread_runner::ThreadRunner::new(),
        git: Arc::new(GitService::new()),
        git_remote: Arc::new(GitRemoteService::new(cfg.home_dir.clone())),
    };
    (state, database)
}

fn build_router(state: AppState) -> Router {
    let public = devinorium::api::auth::router();
    let protected = Router::new()
        .route("/api/auth/me", get(devinorium::api::auth::me))
        .route(
            "/api/auth/totp/setup",
            axum::routing::post(devinorium::api::auth::totp_setup),
        )
        .route(
            "/api/auth/totp/verify",
            axum::routing::post(devinorium::api::auth::totp_verify),
        )
        .route(
            "/api/auth/totp/disable",
            axum::routing::post(devinorium::api::auth::totp_disable),
        )
        .merge(devinorium::api::accounts::router())
        .merge(devinorium::api::devices::router())
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            auth::middleware::require_auth,
        ));
    Router::new()
        .merge(public)
        .merge(protected)
        .with_state(state)
}

async fn read_body(body: axum::body::Body) -> String {
    use axum::body::to_bytes;
    let bytes = to_bytes(body, 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

async fn login(app: &Router, username: &str, password: &str) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"username":"{username}","password":"{password}"}}"#
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

async fn login_token(app: &Router, username: &str, password: &str) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"username":"{username}","password":"{password}"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    v["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn bootstrap_creates_owner() {
    let (_state, db) = make_app("owner", "supersecret123").await;
    let users = db.list_users().await.unwrap();
    assert_eq!(users.len(), 1);
    assert_eq!(users[0].username, "owner");
    assert_eq!(users[0].role, "user");
    assert!(users[0].is_owner);
}

#[tokio::test]
async fn login_succeeds_with_correct_password() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"ok\":true"), "body: {body}");
}

#[tokio::test]
async fn login_returns_token_in_response() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["username"], "owner");
    assert!(v["token"].as_str().unwrap().len() >= 16);
}

#[tokio::test]
async fn login_fails_with_wrong_password() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"owner","password":"wrong"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn login_fails_for_nonexistent_user() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"ghost","password":"whatever12"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn me_requires_auth() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
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
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn me_includes_is_owner() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"is_owner\":true"), "body: {body}");
    assert!(body.contains("\"role\":\"user\""), "body: {body}");
}

#[tokio::test]
async fn full_login_then_me_flow() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());

    // Login and capture cookie.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let set_cookie = resp
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    let token = set_cookie
        .split(';')
        .next()
        .unwrap()
        .strip_prefix("devinorium_session=")
        .unwrap()
        .to_string();

    // Use cookie to call /me.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", format!("devinorium_session={token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"role\":\"user\""), "body: {body}");
    assert!(body.contains("\"username\":\"owner\""), "body: {body}");
    assert!(body.contains("\"is_owner\":true"), "body: {body}");
}

#[tokio::test]
async fn owner_creates_user() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_body(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["username"], "alice");
    assert!(v["id"].is_i64());

    // The new user can log in.
    let _ = login(&app, "alice", "alicepass123").await;
}

#[tokio::test]
async fn non_owner_cannot_create_user() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let owner_cookie = login(&app, "owner", "supersecret123").await;

    // Owner creates alice.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &owner_cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Alice tries to create another user and is forbidden.
    let alice_cookie = login(&app, "alice", "alicepass123").await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &alice_cookie)
                .body(Body::from(
                    r#"{"username":"bob","password":"bobpass12345"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn owner_can_list_users() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    // Create a second user so the list has more than one entry.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/users")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    let users = serde_json::from_str::<Vec<serde_json::Value>>(&body).unwrap();
    assert_eq!(users.len(), 2);
    assert!(users
        .iter()
        .any(|u| u["username"] == "owner" && u["is_owner"] == true));
    assert!(users
        .iter()
        .any(|u| u["username"] == "alice" && u["is_owner"] == false));
    // Sorted by id.
    assert!(users[0]["id"].as_i64().unwrap() < users[1]["id"].as_i64().unwrap());
}

#[tokio::test]
async fn owner_can_disable_user() {
    let (state, db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    // Create bob.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"bob","password":"bobpass12345"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let bob_id = serde_json::from_str::<serde_json::Value>(&read_body(resp.into_body()).await)
        .unwrap()["id"]
        .as_i64()
        .unwrap();

    // Bob can log in and use /me.
    let bob_cookie = login(&app, "bob", "bobpass12345").await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", &bob_cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Owner disables bob.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/users/{bob_id}"))
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(r#"{"disabled":true}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"ok\":true"), "body: {body}");

    // Verify disabled flag in the DB.
    let bob = db.get_user_by_id(bob_id).await.unwrap().unwrap();
    assert!(bob.disabled);

    // Bob's existing session is now rejected.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("cookie", &bob_cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn totp_setup_and_verify_flow() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());

    // Login.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let token = resp
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .strip_prefix("devinorium_session=")
        .unwrap()
        .to_string();

    // TOTP setup returns a secret.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/totp/setup")
                .header("cookie", format!("devinorium_session={token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("secret"), "body: {body}");
    let secret = serde_json::from_str::<serde_json::Value>(&body).unwrap()["secret"]
        .as_str()
        .unwrap()
        .to_string();

    // Generate a valid current code from the secret.
    use totp_rs::{Algorithm, Secret, TOTP};
    let totp = TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        Secret::Encoded(secret.clone()).to_bytes().unwrap(),
        Some("devinorium".into()),
        "owner".into(),
    )
    .unwrap();
    let code = totp.generate_current().unwrap();

    // Verify -> enables TOTP.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/totp/verify")
                .header("cookie", format!("devinorium_session={token}"))
                .header("content-type", "application/json")
                .body(Body::from(format!(r#"{{"code":"{code}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Now login should require TOTP.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"owner","password":"supersecret123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"totp_required\":true"), "body: {body}");
}

#[tokio::test]
async fn owner_cannot_disable_self() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri("/api/users/1")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(r#"{"disabled":true}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_user_rejects_short_password() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"short12345"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn owner_cannot_disable_another_owner() {
    let (state, db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;

    // Create a normal user and promote them to owner in the DB.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let alice_id = serde_json::from_str::<serde_json::Value>(&read_body(resp.into_body()).await)
        .unwrap()["id"]
        .as_i64()
        .unwrap();
    db.set_user_owner(alice_id, true).await.unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/users/{alice_id}"))
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(r#"{"disabled":true}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn bearer_token_allows_access_to_me() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let token = login_token(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    assert!(body.contains("\"username\":\"owner\""), "body: {body}");
}

#[tokio::test]
async fn device_list_and_revoke() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let cookie = login(&app, "owner", "supersecret123").await;
    let token = login_token(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/devices")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_body(resp.into_body()).await;
    let devices: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    assert!(devices.len() >= 1);
    let device = devices
        .iter()
        .find(|d| {
            d["token_prefix"]
                .as_str()
                .map_or(false, |p| token.starts_with(p))
        })
        .expect("token session should be listed");
    let device_id = device["device_id"].as_str().unwrap().to_string();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/devices/revoke")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(format!(r#"{{"device_id":"{device_id}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/me")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn cannot_revoke_device_owned_by_another_user() {
    let (state, _db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let owner_cookie = login(&app, "owner", "supersecret123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header("content-type", "application/json")
                .header("cookie", &owner_cookie)
                .body(Body::from(
                    r#"{"username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let alice_token = login_token(&app, "alice", "alicepass123").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/devices")
                .header("authorization", format!("Bearer {alice_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let devices: Vec<serde_json::Value> =
        serde_json::from_str(&read_body(resp.into_body()).await).unwrap();
    assert!(!devices.is_empty());
    let device_id = devices[0]["device_id"].as_str().unwrap().to_string();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/devices/revoke")
                .header("content-type", "application/json")
                .header("cookie", &owner_cookie)
                .body(Body::from(format!(r#"{{"device_id":"{device_id}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}


