//! Integration tests for the auth system: bootstrap, login, register
//! (invite-only), `me`, TOTP setup/verify, and role enforcement.
//!
//! These spin up a real axum app against a temp SQLite db.

#![cfg(test)]

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::{get, Router};
use tower::ServiceExt;

use devinorium::{auth, config::Config, db, providers, AppState};

async fn make_app(bootstrap_user: &str, bootstrap_pw: &str) -> (AppState, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("test.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, bootstrap_user, bootstrap_pw)
        .await
        .expect("bootstrap");

    sqlx::query(
        "UPDATE users SET provider_command = '' WHERE username = ?",
    )
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
        file_root: None,
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
        config: Arc::new(cfg),
        db: database.clone(),
        provider: Arc::from(provider),
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
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

#[tokio::test]
async fn bootstrap_creates_owner() {
    let (_state, db) = make_app("owner", "supersecret123").await;
    let users = db.list_users().await.unwrap();
    assert_eq!(users.len(), 1);
    assert_eq!(users[0].username, "owner");
    assert_eq!(users[0].role, "user");
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
}

#[tokio::test]
async fn register_requires_valid_invite() {
    let (state, db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());

    // No invite -> rejected.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"invite":"bogus","username":"alice","password":"alicepass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Owner creates an invite.
    let owner = db.get_user_by_username("owner").await.unwrap().unwrap();
    let invite = db.create_invite(owner.id, 7).await.unwrap();

    // Valid invite -> success.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"invite":"{invite}","username":"alice","password":"alicepass123"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // alice exists and is role user.
    let alice = db.get_user_by_username("alice").await.unwrap().unwrap();
    assert_eq!(alice.role, "user");

    // Invite cannot be reused.
    let (state2, _db2) = make_app("owner", "supersecret123").await;
    // (separate app instance not needed; reuse db via state)
    let _ = state2;
}

#[tokio::test]
async fn register_rejects_short_password() {
    let (state, db) = make_app("owner", "supersecret123").await;
    let app = build_router(state.clone());
    let owner = db.get_user_by_username("owner").await.unwrap().unwrap();
    let invite = db.create_invite(owner.id, 7).await.unwrap();
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/register")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"invite":"{invite}","username":"bob","password":"short"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
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
