//! Integration tests for the Web Push API: subscription CRUD, validation,
//! auth/ownership, and the disabled-service fallbacks.

#![cfg(test)]

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

fn b64u(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

async fn app_state(push_enabled: bool) -> (AppState, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("push.db").display());
    let database = db::Db::connect(&db_url).await.unwrap();
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .unwrap();

    sqlx::query("UPDATE users SET provider_command = '' WHERE username = 'owner'")
        .execute(database.pool())
        .await
        .unwrap();

    let home_dir = dir.join("files");
    std::fs::create_dir_all(&home_dir).unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir,
        default_model: "glm-5-2".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
    };

    let provider = providers::build_provider(providers::ProviderConfig {
        id: "devin-cli".into(),
        command: "devin".into(),
        default_model: "glm-5-2".into(),
    })
    .unwrap();

    let push = if push_enabled {
        devinorium::push::PushService::new(database.clone(), cfg.push_contact.clone())
            .await
            .unwrap()
    } else {
        devinorium::push::PushService::disabled()
    };

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
        push,
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
    };
    (state, database)
}

async fn make_app(push_enabled: bool) -> (Router, db::Db) {
    let (state, database) = app_state(push_enabled).await;
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

async fn body_str(b: Body) -> String {
    let bytes = to_bytes(b, 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
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

/// A syntactically valid subscription body (the point does not need to be on
/// the curve for registration; only delivery does ECDH).
fn valid_sub(endpoint: &str) -> String {
    let mut point = vec![0x04u8];
    point.extend_from_slice(&[7u8; 64]);
    serde_json::json!({
        "endpoint": endpoint,
        "keys": { "p256dh": b64u(&point), "auth": b64u(&[9u8; 16]) },
        "lang": "en",
    })
    .to_string()
}

#[tokio::test]
async fn vapid_key_404_when_disabled_and_present_when_enabled() {
    let (app, _db) = make_app(false).await;
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/push/vapid-key", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let (app, _db) = make_app(true).await;
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/push/vapid-key", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    let key = body["public_key"].as_str().unwrap();
    // Uncompressed P-256 point, base64url without padding.
    use base64::Engine;
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(key)
        .unwrap();
    assert_eq!(raw.len(), 65);
    assert_eq!(raw[0], 0x04);
}

#[tokio::test]
async fn vapid_key_persists_across_service_restarts() {
    let (state, db) = app_state(true).await;
    let first = state.push.vapid_public_key().unwrap();
    drop(state);
    let again = devinorium::push::PushService::new(db, "mailto:test@localhost".into())
        .await
        .unwrap();
    assert_eq!(first, again.vapid_public_key().unwrap());
}

#[tokio::test]
async fn subscribe_requires_auth() {
    let (app, _db) = make_app(true).await;
    let resp = app
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri("/api/push/subscriptions")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from(valid_sub("https://push.example.com/x")))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn subscribe_validates_endpoint_and_keys() {
    let (app, _db) = make_app(true).await;
    let cookie = login(&app).await;

    // Non-http(s) endpoints are rejected (SSRF guard).
    let bad = serde_json::json!({
        "endpoint": "ftp://evil.example.com/x",
        "keys": { "p256dh": b64u(&[4u8; 65]), "auth": b64u(&[9u8; 16]) },
    })
    .to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/push/subscriptions", &cookie, &bad))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Wrong-size p256dh is rejected.
    let bad = serde_json::json!({
        "endpoint": "https://push.example.com/x",
        "keys": { "p256dh": b64u(&[4u8; 10]), "auth": b64u(&[9u8; 16]) },
    })
    .to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/push/subscriptions", &cookie, &bad))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Garbage base64 is rejected.
    let bad = serde_json::json!({
        "endpoint": "https://push.example.com/x",
        "keys": { "p256dh": "!!!", "auth": b64u(&[9u8; 16]) },
    })
    .to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/push/subscriptions", &cookie, &bad))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Plain http endpoints are rejected — the VAPID JWT must never travel
    // unencrypted and browsers only ever mint https endpoints.
    let bad = serde_json::json!({
        "endpoint": "http://push.example.com/x",
        "keys": { "p256dh": b64u(&[4u8; 65]), "auth": b64u(&[9u8; 16]) },
    })
    .to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/push/subscriptions", &cookie, &bad))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // A 65-byte p256dh that does not start with the uncompressed-point
    // marker (0x04) is rejected before it ever reaches ECDH.
    let mut point = vec![0x05u8];
    point.extend_from_slice(&[7u8; 64]);
    let bad = serde_json::json!({
        "endpoint": "https://push.example.com/x",
        "keys": { "p256dh": b64u(&point), "auth": b64u(&[9u8; 16]) },
    })
    .to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/push/subscriptions", &cookie, &bad))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn subscribe_is_capped_per_user() {
    let (app, _db) = make_app(true).await;
    let cookie = login(&app).await;
    for i in 0..16 {
        let resp = app
            .clone()
            .oneshot(authed(
                "PUT",
                "/api/push/subscriptions",
                &cookie,
                &valid_sub(&format!("https://push.example.com/sub/{i}")),
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }
    // A 17th distinct endpoint is rejected.
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/push/subscriptions",
            &cookie,
            &valid_sub("https://push.example.com/sub/16"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
    // Resubscribing an existing endpoint still works at the cap.
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/push/subscriptions",
            &cookie,
            &valid_sub("https://push.example.com/sub/0"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn subscribe_list_and_unsubscribe_roundtrip() {
    let (app, db) = make_app(true).await;
    let cookie = login(&app).await;
    let endpoint = "https://push.example.com/sub/1";

    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/push/subscriptions",
            &cookie,
            &valid_sub(endpoint),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/push/subscriptions", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(endpoint));
    // The listing must not leak the subscription secrets.
    assert!(!body.contains("p256dh"));
    assert!(!body.contains("auth"));

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            "/api/push/subscriptions",
            &cookie,
            &serde_json::json!({"endpoint": endpoint}).to_string(),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let owner_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(db.pool())
        .await
        .unwrap();
    assert!(db
        .push_subscriptions_for_user(owner_id)
        .await
        .unwrap()
        .is_empty());
}

/// Create a second account and return its id.
async fn second_user(db: &db::Db) -> i64 {
    db.create_user(devinorium::db::NewUser {
        username: "other".into(),
        password_hash: "x".into(),
        is_owner: false,
    })
    .await
    .unwrap()
    .id
}

#[tokio::test]
async fn unsubscribe_scoped_to_owner() {
    let (app, db) = make_app(true).await;
    let cookie = login(&app).await;
    let endpoint = "https://push.example.com/sub/2";

    // Seed a subscription owned by a different user directly.
    let other = second_user(&db).await;
    db.upsert_push_subscription(other, endpoint, "k", "a", "en", "")
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            "/api/push/subscriptions",
            &cookie,
            &serde_json::json!({"endpoint": endpoint}).to_string(),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    // Not deleted: the caller does not own it.
    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM push_subscriptions WHERE endpoint = ?")
            .bind(endpoint)
            .fetch_one(db.pool())
            .await
            .unwrap();
    assert_eq!(count, 1);
}

#[tokio::test]
async fn resubscribe_rebinds_endpoint_to_new_owner() {
    let (_app, db) = make_app(true).await;
    let endpoint = "https://push.example.com/sub/3";
    let other = second_user(&db).await;
    let owner_id: i64 = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(db.pool())
        .await
        .unwrap();
    db.upsert_push_subscription(owner_id, endpoint, "k1", "a1", "en", "")
        .await
        .unwrap();
    db.upsert_push_subscription(other, endpoint, "k2", "a2", "zh", "")
        .await
        .unwrap();
    let rows = db.push_subscriptions_for_user(other).await.unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].p256dh, "k2");
    assert_eq!(rows[0].lang, "zh");
    assert!(db
        .push_subscriptions_for_user(owner_id)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn test_push_reports_enabled_state() {
    let (app, _db) = make_app(false).await;
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/push/test", &cookie, "{}"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // Enabled but with no subscriptions, nothing is delivered.
    let (app, _db) = make_app(true).await;
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/push/test", &cookie, "{}"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(body["sent"], 0);
}

#[tokio::test]
async fn prune_removes_dead_endpoints() {
    let (_app, db) = make_app(true).await;
    db.upsert_push_subscription(1, "https://push.example.com/dead", "k", "a", "en", "")
        .await
        .unwrap();
    db.prune_push_endpoint("https://push.example.com/dead")
        .await
        .unwrap();
    assert!(db.push_subscriptions_for_user(1).await.unwrap().is_empty());
}
