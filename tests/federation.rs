//! Integration tests for satellite pairing: the node protocol surface
//! (`/api/node/*`), the pairing-code handshake, and the hub-side node
//! endpoints (`/api/federation/*`).

#![cfg(test)]

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use tower::ServiceExt;

use devinorium::satellite::SatelliteState;
use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers, AppState,
};

async fn make_state() -> (AppState, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("fed.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    sqlx::query("UPDATE users SET provider_command = ''")
        .execute(database.pool())
        .await
        .unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: dir.join("home"),
        default_model: "stub-1".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
        satellite: false,
        node_name: "test-hub".into(),
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
        machine_grants: devinorium::machine_grants::MachineGrants::new(),
        push: devinorium::push::PushService::disabled(),
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
        http_client: devinorium::federation::http_client(),
        remote_terminals: std::sync::Arc::new(std::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
        rate_limiter: devinorium::security::RateLimiter::new(500, 2.0),
    };
    (state, database)
}

fn test_config(dir: &std::path::Path, satellite: bool) -> Config {
    Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url: format!("sqlite:{}?mode=rwc", dir.join("x.db").display()),
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        home_dir: dir.join("home"),
        default_model: "stub-1".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
        satellite,
        node_name: "test-sat".into(),
    }
}

async fn serve(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await;
    });
    format!("http://{addr}")
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

async fn body_str(b: Body) -> String {
    let bytes = to_bytes(b, 8 * 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

fn authed(method: &str, uri: &str, cookie: &str, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::HOST, "localhost")
        .header(header::ORIGIN, "http://localhost")
        .header(header::COOKIE, cookie);
    if !body.is_empty() {
        b = b.header("content-type", "application/json");
    }
    b.body(Body::from(body.to_string())).unwrap()
}

/// A satellite app on a temp home dir plus its URL. Keeps the tempdir and
/// state alive for the test via the returned guards.
struct Satellite {
    url: String,
    code: String,
    state: std::sync::Arc<SatelliteState>,
    _dir: tempfile::TempDir,
}

async fn start_satellite() -> Satellite {
    let dir = tempfile::tempdir().expect("tempdir");
    let cfg = test_config(dir.path(), true);
    let state = SatelliteState::load(&cfg).await;
    let code = state.pairing_code.read().await.clone();
    let app = devinorium::satellite::build_app(state.clone());
    let url = serve(app).await;
    Satellite {
        url,
        code,
        state,
        _dir: dir,
    }
}

// ---------------------------------------------------------------------
// Satellite surface
// ---------------------------------------------------------------------

#[tokio::test]
async fn satellite_info_reports_satellite_mode() {
    let sat = start_satellite().await;
    let resp = reqwest::get(format!("{}/api/node/info", sat.url))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["satellite"], true);
    assert_eq!(v["node_id"], sat.state.node_id);
    assert_eq!(v["name"], "test-sat");
}

#[tokio::test]
async fn satellite_pair_issues_token_and_gates_api() {
    let sat = start_satellite().await;
    let client = reqwest::Client::new();

    // Without a token every protected endpoint rejects.
    for path in ["files/stat", "terminal/sessions"] {
        let resp = client
            .post(format!("{}/api/node/{path}", sat.url))
            .body("{}")
            .header("content-type", "application/json")
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 401, "{path}");
    }

    // Wrong code: 401.
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": "XXXX-XXXX-XXXX-XXXX"}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 401);

    // Correct code (with dashes stripped on input): issues a token.
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code.replace('-', "")}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let v: serde_json::Value = resp.json().await.unwrap();
    let token = v["token"].as_str().unwrap().to_string();
    assert_eq!(token.len(), 64);
    assert_eq!(v["node_id"], sat.state.node_id);

    // The issued token unlocks the API.
    let resp = client
        .post(format!("{}/api/node/files/stat", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({"paths": ["/tmp"]}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["results"]["/tmp"]["exists"], true);
}

#[tokio::test]
async fn satellite_pair_locks_out_after_failed_attempts() {
    let sat = start_satellite().await;
    let client = reqwest::Client::new();
    for _ in 0..10 {
        let resp = client
            .post(format!("{}/api/node/pair", sat.url))
            .json(&serde_json::json!({"code": "AAAA-AAAA-AAAA-AAAA"}))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 401);
    }
    // Even the right code is locked out now.
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 429);
}

#[tokio::test]
async fn satellite_identity_survives_reload() {
    let dir = tempfile::tempdir().expect("tempdir");
    let cfg = test_config(dir.path(), true);
    let first = SatelliteState::load(&cfg).await;
    let first_id = first.node_id.clone();
    let token = first.issue_token().await;
    drop(first);

    let second = SatelliteState::load(&cfg).await;
    assert_eq!(second.node_id, first_id);
    assert!(second.has_token(&token).await);
    // The pairing code rotates every boot.
    assert_ne!(*second.pairing_code.read().await, "");
}

#[tokio::test]
async fn satellite_files_and_git_dispatch() {
    let sat = start_satellite().await;
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code}))
        .send()
        .await
        .unwrap();
    let token = resp.json::<serde_json::Value>().await.unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string();

    // File write + read round trip.
    let resp = client
        .put(format!("{}/api/node/files/content", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "root": sat.state.home_dir.to_string_lossy(),
            "path": "hello.txt",
            "content": "hi there",
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);

    let resp = client
        .post(format!("{}/api/node/files/stat", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({"root": sat.state.home_dir.to_string_lossy(), "paths": ["hello.txt"]}))
        .send()
        .await
        .unwrap();
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["results"]["hello.txt"]["exists"], true);

    // Git dispatch on a non-repo reports not_repo, not a server error.
    let resp = client
        .post(format!("{}/api/node/git/repo_status", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({"repo": sat.state.home_dir.to_string_lossy()}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["is_repo"], false);
}

#[tokio::test]
async fn satellite_run_rejects_bad_requests() {
    let sat = start_satellite().await;
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code}))
        .send()
        .await
        .unwrap();
    let token = resp.json::<serde_json::Value>().await.unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string();

    // Unknown provider: 400.
    let resp = client
        .post(format!("{}/api/node/run", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "run_id": "r1",
            "prompt": "hi",
            "provider": {"id": "no-such-provider", "command": "x", "default_model": "m"},
            "options": {"working_dir": "/tmp", "model": "m", "permission_mode": "normal", "interaction_mode": "code"},
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 400);

    // Invalid run id: 400.
    let resp = client
        .post(format!("{}/api/node/run", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "run_id": "bad id!",
            "prompt": "hi",
            "provider": {"id": "devin-cli", "command": "devin", "default_model": "m"},
            "options": {"working_dir": "/tmp", "model": "m", "permission_mode": "normal", "interaction_mode": "code"},
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 400);

    // Unknown callback: 404.
    let resp = client
        .post(format!("{}/api/node/callback", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({
            "request_id": "nope",
            "outcome": {"type": "permission_cancel"},
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

// ---------------------------------------------------------------------
// Hub endpoints
// ---------------------------------------------------------------------

#[tokio::test]
async fn hub_nodes_endpoints_owner_only() {
    let (state, _db) = make_state().await;
    let app = devinorium::build_app(state);

    for (method, uri) in [
        ("GET", "/api/federation/nodes"),
        ("POST", "/api/federation/nodes/pair"),
        ("DELETE", "/api/federation/nodes/node-1"),
    ] {
        let resp = app
            .clone()
            .oneshot(authed(method, uri, "", "{}"))
            .await
            .unwrap();
        assert!(
            matches!(
                resp.status(),
                StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
            ),
            "{method} {uri} -> {}",
            resp.status()
        );
    }
}

#[tokio::test]
async fn hub_pair_validates_input() {
    let (state, _db) = make_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    for body in [
        r#"{"url":"not-a-url","code":"ABCD-EFGH"}"#,
        r#"{"url":"http://x/path","code":"ABCD-EFGH"}"#,
        r#"{"url":"ftp://host:7878","code":"ABCD-EFGH"}"#,
        r#"{"url":"http://host:7878","code":""}"#,
    ] {
        let resp = app
            .clone()
            .oneshot(authed("POST", "/api/federation/nodes/pair", &cookie, body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{body}");
    }
}

#[tokio::test]
async fn hub_pair_lists_and_removes_satellite() {
    let sat = start_satellite().await;
    let (state, db) = make_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    // Pair against the live satellite.
    let body = format!(
        r#"{{"url":"{}","code":"{}","name":"My node"}}"#,
        sat.url, sat.code
    );
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/federation/nodes/pair", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    let node_id = v["id"].as_str().unwrap().to_string();
    assert_eq!(node_id, sat.state.node_id);
    assert_eq!(v["name"], "My node");
    assert_eq!(v["online"], true);

    // The token landed on the row, but the list payload does not leak it.
    let row = db.get_federation_node(&node_id).await.unwrap().unwrap();
    let token = row.token.clone().unwrap();
    assert_eq!(token.len(), 64);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/federation/nodes", &cookie, ""))
        .await
        .unwrap();
    let listing = body_str(resp.into_body()).await;
    assert!(listing.contains(&node_id));
    assert!(!listing.contains(&token));

    // The stored credential works against the satellite directly.
    let resp = reqwest::Client::new()
        .post(format!("{}/api/node/files/stat", sat.url))
        .bearer_auth(&token)
        .json(&serde_json::json!({"paths": ["/tmp"]}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);

    // Remove the node.
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/federation/nodes/{node_id}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(db.get_federation_node(&node_id).await.unwrap().is_none());
}

#[tokio::test]
async fn hub_pair_wrong_code_and_dead_node() {
    let sat = start_satellite().await;
    let (state, _db) = make_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = format!(r#"{{"url":"{}","code":"AAAA-BBBB-CCCC-DDDD"}}"#, sat.url);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/federation/nodes/pair", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body = r#"{"url":"http://127.0.0.1:1","code":"AAAA-BBBB-CCCC-DDDD"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/federation/nodes/pair", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn hub_delete_missing_node_is_404() {
    let (state, _db) = make_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;
    let resp = app
        .oneshot(authed("DELETE", "/api/federation/nodes/nope", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn pairing_code_is_single_use() {
    let sat = start_satellite().await;
    let client = reqwest::Client::new();

    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);

    // The printed code pairs one hub; a second attempt gets 410 even with
    // the right code.
    let resp = client
        .post(format!("{}/api/node/pair", sat.url))
        .json(&serde_json::json!({"code": sat.code}))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 410);
    let v: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(v["kind"], "consumed");
}

#[tokio::test]
async fn unpaired_node_project_does_not_fall_back_to_local() {
    let sat = start_satellite().await;
    let (state, db) = make_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    // Pair and create a project on the node.
    let dir = tempfile::tempdir().expect("tempdir");
    let proj_path = dir.path().join("nodeproj");
    let body = format!(r#"{{"url":"{}","code":"{}"}}"#, sat.url, sat.code);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/federation/nodes/pair", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    let node_id = v["id"].as_str().unwrap().to_string();

    let body = serde_json::json!({
        "name": "remote",
        "path": proj_path.to_string_lossy(),
        "node_id": node_id,
    });
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body.to_string()))
        .await
        .unwrap();
    if resp.status() != StatusCode::CREATED {
        panic!("create failed: {}", body_str(resp.into_body()).await);
    }
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    let project_id = v["id"].as_i64().unwrap();

    // Unpair the node. The project must fail loudly, never touch the
    // local filesystem.
    assert!(db.delete_federation_node(&node_id).await.unwrap());

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={project_id}&path="),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{project_id}/git/status"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}
