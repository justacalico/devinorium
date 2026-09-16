//! Integration tests for the Machines feature: owner-managed CRUD, the
//! connection probe, `machine_ids` on send, and the token-gated
//! machine-control endpoints an agent uses during a run.

#![cfg(test)]

use std::sync::Arc;

use async_trait::async_trait;
use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tower::ServiceExt;
use uuid::Uuid;

use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    machine_grants::MachineGrants,
    providers::{
        MessagePart, ModelInfo, Provider, SendRequest, SendResponse, StartRequest, StartResponse,
    },
    AppState,
};

/// Echoes the effective prompt back so tests can assert what the provider
/// was told about referenced machines.
struct EchoProvider;

#[async_trait]
impl Provider for EchoProvider {
    fn id(&self) -> &str {
        "stub"
    }
    fn name(&self) -> &str {
        "Stub"
    }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        Ok(vec![ModelInfo {
            id: "stub-1".into(),
            label: "Stub".into(),
            cost_tier: "free".into(),
            family: "stub".into(),
            cost_summary: "Free".into(),
            max_context_tokens: 200_000,
            max_output_tokens: 32_000,
            is_new: false,
            is_beta: false,
            default_reasoning_effort: None,
            supported_reasoning_efforts: vec![],
        }])
    }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let reply = format!("echo: {}", req.prompt);
        Ok(StartResponse {
            session_id: "stub-session".into(),
            reply: reply.clone(),
            thinking: String::new(),
            parts: vec![MessagePart::text(reply)],
            title: "Stub Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let reply = format!("echo: {}", req.prompt);
        Ok(SendResponse {
            reply: reply.clone(),
            thinking: String::new(),
            parts: vec![MessagePart::text(reply)],
            usage: None,
        })
    }
    async fn health_check(&self) -> anyhow::Result<()> {
        Ok(())
    }
}

async fn make_app() -> (Router, db::Db, MachineGrants) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("machines.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    // Fall back to the stub provider instead of spawning a real CLI.
    sqlx::query("UPDATE users SET provider_command = '' WHERE username = 'owner'")
        .execute(database.pool())
        .await
        .unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 7878,
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
        dev_mode: false,
    };

    let machine_grants = MachineGrants::new();
    let state = AppState {
        config: Arc::new(cfg.clone()),
        db: database.clone(),
        provider: Arc::new(EchoProvider) as Arc<dyn Provider>,
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
        machine_grants: machine_grants.clone(),
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
    };
    (devinorium::build_app(state), database, machine_grants)
}

async fn login_as(app: &Router, username: &str, password: &str) -> String {
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
                    r#"{{"username":"{username}","password":"{password}"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let sc = resp.headers().get("set-cookie").unwrap().to_str().unwrap();
    sc.split(';').next().unwrap().to_string()
}

async fn login(app: &Router) -> String {
    login_as(app, "owner", "supersecret123").await
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

async fn create_machine(app: &Router, cookie: &str, body: &str) -> (StatusCode, String) {
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/machines", cookie, body))
        .await
        .unwrap();
    let status = resp.status();
    (status, body_str(resp.into_body()).await)
}

/// A minimal RFB 3.8 server: offers only None auth, serves a solid
/// framebuffer, and records pointer/key events for assertions.
struct FakeVnc {
    port: u16,
    events: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
}

impl FakeVnc {
    async fn start(width: u16, height: u16) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let ev = events.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let ev = ev.clone();
                tokio::spawn(async move {
                    let _ = Self::conn(&mut s, width, height, ev).await;
                });
            }
        });
        Self { port, events }
    }

    async fn conn(
        s: &mut TcpStream,
        width: u16,
        height: u16,
        events: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
    ) -> std::io::Result<()> {
        s.write_all(b"RFB 003.008\n").await?;
        let mut banner = [0u8; 12];
        s.read_exact(&mut banner).await?;
        s.write_all(&[1, 1]).await?; // one security type: None
        let mut choice = [0u8; 1];
        s.read_exact(&mut choice).await?;
        s.write_all(&0u32.to_be_bytes()).await?; // SecurityResult ok
        let mut init = [0u8; 1];
        s.read_exact(&mut init).await?; // ClientInit
        let mut server_init = Vec::with_capacity(24);
        server_init.extend_from_slice(&width.to_be_bytes());
        server_init.extend_from_slice(&height.to_be_bytes());
        server_init.extend_from_slice(&[0u8; 16]);
        server_init.extend_from_slice(&4u32.to_be_bytes());
        server_init.extend_from_slice(b"fake");
        s.write_all(&server_init).await?;

        loop {
            let mut ty = [0u8; 1];
            if s.read_exact(&mut ty).await.is_err() {
                return Ok(());
            }
            match ty[0] {
                0 => {
                    let mut rest = [0u8; 19];
                    s.read_exact(&mut rest).await?;
                }
                2 => {
                    let mut rest = [0u8; 3];
                    s.read_exact(&mut rest).await?;
                    let n = u16::from_be_bytes([rest[1], rest[2]]) as usize;
                    let mut skip = vec![0u8; n * 4];
                    s.read_exact(&mut skip).await?;
                }
                3 => {
                    let mut rest = [0u8; 9];
                    s.read_exact(&mut rest).await?;
                    let (x, y, w, h) = (
                        u16::from_be_bytes([rest[1], rest[2]]),
                        u16::from_be_bytes([rest[3], rest[4]]),
                        u16::from_be_bytes([rest[5], rest[6]]),
                        u16::from_be_bytes([rest[7], rest[8]]),
                    );
                    let mut msg = Vec::new();
                    msg.extend_from_slice(&[0, 0, 0, 1]);
                    msg.extend_from_slice(&x.to_be_bytes());
                    msg.extend_from_slice(&y.to_be_bytes());
                    msg.extend_from_slice(&w.to_be_bytes());
                    msg.extend_from_slice(&h.to_be_bytes());
                    msg.extend_from_slice(&0i32.to_be_bytes());
                    for _ in 0..(w as usize * h as usize) {
                        msg.extend_from_slice(&[0, 255, 0, 0]); // B,G,R,X green
                    }
                    s.write_all(&msg).await?;
                }
                4 => {
                    let mut rest = [0u8; 7];
                    s.read_exact(&mut rest).await?;
                    let mut m = vec![4u8];
                    m.extend_from_slice(&rest);
                    events.lock().unwrap().push(m);
                }
                5 => {
                    let mut rest = [0u8; 5];
                    s.read_exact(&mut rest).await?;
                    let mut m = vec![5u8];
                    m.extend_from_slice(&rest);
                    events.lock().unwrap().push(m);
                }
                6 => {
                    let mut rest = [0u8; 7];
                    s.read_exact(&mut rest).await?;
                    let n = u32::from_be_bytes([rest[3], rest[4], rest[5], rest[6]]) as usize;
                    let mut skip = vec![0u8; n.min(1024 * 1024)];
                    s.read_exact(&mut skip).await?;
                }
                _ => return Ok(()),
            }
        }
    }
}

#[tokio::test]
async fn machines_require_auth() {
    let (app, _db, _g) = make_app().await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/machines")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn machine_crud_lifecycle() {
    let (app, _db, _g) = make_app().await;
    let cookie = login(&app).await;

    let (status, body) = create_machine(
        &app,
        &cookie,
        r#"{"name":"gaming pc","host":"vnc://192.168.1.10/","port":5901,"password":"hunter2"}"#,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "body: {body}");
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    let id = v["id"].as_i64().unwrap();
    // Scheme and path are stripped from the stored host.
    assert_eq!(v["host"], "192.168.1.10");
    assert_eq!(v["has_password"], true);
    // The password is never serialized.
    assert!(v.get("password").is_none());

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/machines", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("gaming pc"), "body: {body}");
    assert!(!body.contains("hunter2"), "body: {body}");

    // Update name/port without touching the password.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/machines/{id}"),
            &cookie,
            r#"{"name":"renamed","port":5902}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(v["name"], "renamed");
    assert_eq!(v["port"], 5902);
    assert_eq!(v["has_password"], true);

    // Explicit empty password clears it.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/machines/{id}"),
            &cookie,
            r#"{"password":""}"#,
        ))
        .await
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(v["has_password"], false);

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/machines/{id}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/machines/{id}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn machine_validation_rejects_bad_input() {
    let (app, _db, _g) = make_app().await;
    let cookie = login(&app).await;

    for body in [
        r#"{"name":"","host":"h"}"#,
        r#"{"name":"m","host":""}"#,
        r#"{"name":"m","host":"has space"}"#,
        r#"{"name":"m","host":"h","port":0}"#,
        r#"{"name":"m","host":"h","port":70000}"#,
    ] {
        let (status, body) = create_machine(&app, &cookie, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "body: {body}");
    }

    // Port defaults to 5900 when omitted.
    let (status, body) = create_machine(&app, &cookie, r#"{"name":"m","host":"10.0.0.1"}"#).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&body).unwrap()["port"],
        5900
    );

    // A port embedded in a pasted URL is split out and wins; the stored
    // host stays clean so `host:port` can never become `host:port:port`.
    let (status, body) = create_machine(
        &app,
        &cookie,
        r#"{"name":"m","host":"vnc://192.168.1.20:5901","port":5900}"#,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "body: {body}");
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["host"], "192.168.1.20");
    assert_eq!(v["port"], 5901);

    // Same for bracketed IPv6 with a port.
    let (status, body) =
        create_machine(&app, &cookie, r#"{"name":"m6","host":"[fd00::1]:5902"}"#).await;
    assert_eq!(status, StatusCode::CREATED, "body: {body}");
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["host"], "[fd00::1]");
    assert_eq!(v["port"], 5902);
}

#[tokio::test]
async fn machine_write_routes_require_owner() {
    let (app, db, _g) = make_app().await;
    let cookie = login(&app).await;
    db.create_user(db::NewUser {
        username: "member".into(),
        password_hash: auth::password::hash("memberpass123").unwrap(),
        is_owner: false,
    })
    .await
    .unwrap();
    let member = login_as(&app, "member", "memberpass123").await;

    let (status, _) =
        create_machine(&app, &member, r#"{"name":"m","host":"h","password":"p"}"#).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Members can still list for the composer picker, without secrets.
    let (status, _) =
        create_machine(&app, &cookie, r#"{"name":"m","host":"h","password":"p"}"#).await;
    assert_eq!(status, StatusCode::CREATED);
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/machines", &member, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(!body.contains("\"password\""), "body: {body}");

    let mid = db.list_machines().await.unwrap()[0].id;
    for (method, uri, body) in [
        ("PATCH", format!("/api/machines/{mid}"), r#"{"name":"x"}"#),
        ("DELETE", format!("/api/machines/{mid}"), ""),
        ("POST", format!("/api/machines/{mid}/test"), ""),
    ] {
        let resp = app
            .clone()
            .oneshot(authed(method, &uri, &member, body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN, "{method} {uri}");
    }
}

#[tokio::test]
async fn test_connection_reports_framebuffer() {
    let (app, _db, _g) = make_app().await;
    let cookie = login(&app).await;
    let fake = FakeVnc::start(640, 480).await;

    let (status, body) = create_machine(
        &app,
        &cookie,
        &format!(r#"{{"name":"m","host":"127.0.0.1","port":{}}}"#, fake.port),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/machines/{id}/test"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["width"], 640);
    assert_eq!(v["height"], 480);
    assert_eq!(v["name"], "fake");
}

#[tokio::test]
async fn test_connection_reports_failure_without_leaking() {
    let (app, _db, _g) = make_app().await;
    let cookie = login(&app).await;

    // Port 1 refuses connections instantly.
    let (status, body) = create_machine(
        &app,
        &cookie,
        r#"{"name":"m","host":"127.0.0.1","port":1,"password":"sekrit"}"#,
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/machines/{id}/test"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(v["ok"], false);
    assert!(!v["error"].as_str().unwrap().is_empty());
    assert!(!v["error"].as_str().unwrap().contains("sekrit"));
}

fn grant_request(method: &str, uri: &str, token: &str, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::HOST, "localhost");
    if !token.is_empty() {
        b = b.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    if !body.is_empty() {
        b = b.header("content-type", "application/json");
    }
    b.body(Body::from(body.to_string())).unwrap()
}

#[tokio::test]
async fn machine_control_rejects_bad_tokens() {
    let (app, db, grants) = make_app().await;
    let machine = db.create_machine("m", "127.0.0.1", 5900, "").await.unwrap();

    // No token, then a bogus one.
    let resp = app
        .clone()
        .oneshot(grant_request(
            "GET",
            &format!("/api/machine-control/{}/screenshot", machine.id),
            "",
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let resp = app
        .clone()
        .oneshot(grant_request(
            "GET",
            &format!("/api/machine-control/{}/screenshot", machine.id),
            "mc_deadbeef",
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // A valid token for a different machine is forbidden here.
    let token = grants.create(1, vec![machine.id + 100]).unwrap();
    let resp = app
        .clone()
        .oneshot(grant_request(
            "GET",
            &format!("/api/machine-control/{}/screenshot", machine.id),
            &token,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // A session cookie means nothing on these routes.
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/machine-control/{}/screenshot", machine.id),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn machine_control_screenshot_and_input() {
    let (app, db, grants) = make_app().await;
    let fake = FakeVnc::start(8, 4).await;
    let machine = db
        .create_machine("m", "127.0.0.1", fake.port as i64, "")
        .await
        .unwrap();
    let token = grants.create(1, vec![machine.id]).unwrap();

    let resp = app
        .clone()
        .oneshot(grant_request(
            "GET",
            &format!("/api/machine-control/{}/screenshot", machine.id),
            &token,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers().get(header::CONTENT_TYPE).unwrap(),
        "image/png"
    );
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");

    // Click at (3, 2): move + press + release = three pointer events.
    let resp = app
        .clone()
        .oneshot(grant_request(
            "POST",
            &format!("/api/machine-control/{}/input", machine.id),
            &token,
            r#"{"kind":"click","x":3,"y":2,"button":"left"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let v: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(v["ok"], true);

    for _ in 0..40 {
        if !fake.events.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    let events = fake.events.lock().unwrap().clone();
    assert_eq!(events.len(), 3, "events: {events:?}");
    assert_eq!(events[0], vec![5, 0, 0, 3, 0, 2]);
    assert_eq!(events[1], vec![5, 1, 0, 3, 0, 2]);
    assert_eq!(events[2], vec![5, 0, 0, 3, 0, 2]);

    // Type "Hi": shift+h, then plain i.
    let resp = app
        .clone()
        .oneshot(grant_request(
            "POST",
            &format!("/api/machine-control/{}/input", machine.id),
            &token,
            r#"{"kind":"type","text":"Hi"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Out-of-range coordinates are a 400, not a 502.
    let resp = app
        .clone()
        .oneshot(grant_request(
            "POST",
            &format!("/api/machine-control/{}/input", machine.id),
            &token,
            r#"{"kind":"click","x":99999,"y":0}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn machine_control_404_for_unknown_machine() {
    let (app, _db, grants) = make_app().await;
    let token = grants.create(1, vec![4242]).unwrap();
    let resp = app
        .clone()
        .oneshot(grant_request(
            "GET",
            "/api/machine-control/4242/screenshot",
            &token,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

async fn create_project(app: &Router, cookie: &str) -> i64 {
    let suffix = Uuid::new_v4();
    let body = format!(r#"{{"name":"test-project-{suffix}","path":"test-project-{suffix}"}}"#);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap()
}

async fn make_thread(app: &Router, cookie: &str, project_id: i64, title: &str) -> String {
    let body = format!(r#"{{"project_id":{project_id},"title":"{title}"}}"#);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/threads", cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
}

#[tokio::test]
async fn send_with_machine_ids_scopes_the_run_and_chips_the_message() {
    let (app, db, _g) = make_app().await;
    let cookie = login(&app).await;
    // Point at the fake so a still-live grant answers instantly instead of
    // stalling the poll on a dead TCP connect.
    let fake = FakeVnc::start(4, 4).await;
    let machine = db
        .create_machine("desktop", "127.0.0.1", fake.port as i64, "sekrit")
        .await
        .unwrap();

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----machineboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        reboot it\r\n\
        --{boundary}\r\n\
        Content-Disposition: form-data; name=\"machine_ids\"\r\n\r\n\
        [{}, {}]\r\n\
        --{boundary}--\r\n",
        machine.id,
        machine.id + 999 // stale id is dropped, not an error
    );
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send/stream"))
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .header(
                    "content-type",
                    format!("multipart/form-data; boundary={boundary}"),
                )
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let done = body
        .split("\n\n")
        .find(|b| b.contains("event: done"))
        .expect("done block");
    let data = done.lines().find(|l| l.starts_with("data: ")).unwrap();
    let done_json: serde_json::Value = serde_json::from_str(&data[6..]).unwrap();
    let reply = done_json["content"].as_str().unwrap();

    // The provider saw the machine context with a live grant token,
    // and never the password.
    assert!(reply.contains("\"desktop\" (id "), "reply: {reply}");
    assert!(
        reply.contains(&format!("127.0.0.1:{}", fake.port)),
        "reply: {reply}"
    );
    assert!(reply.contains("Bearer mc_"), "reply: {reply}");
    assert!(reply.contains("/api/machine-control/"), "reply: {reply}");
    assert!(!reply.contains("sekrit"), "reply: {reply}");

    // The user message carries a machine chip; the stale id left none.
    let msgs = db.list_messages(&tid).await.unwrap();
    let atts: serde_json::Value = serde_json::from_str(&msgs[0].attachments).unwrap();
    let atts = atts.as_array().unwrap();
    assert_eq!(atts.len(), 1);
    assert_eq!(atts[0]["kind"], "machine");
    assert_eq!(atts[0]["machine_id"], machine.id);
    assert_eq!(atts[0]["filename"], "desktop");

    // The grant died with the run: the minted token no longer works.
    let token = reply
        .split("Bearer ")
        .nth(1)
        .and_then(|s| s.split_whitespace().next())
        .expect("token in prompt")
        .to_string();
    let mut status = StatusCode::OK;
    for _ in 0..100 {
        let resp = app
            .clone()
            .oneshot(grant_request(
                "GET",
                &format!("/api/machine-control/{}/screenshot", machine.id),
                &token,
                "",
            ))
            .await
            .unwrap();
        status = resp.status();
        if status == StatusCode::UNAUTHORIZED {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

fn multipart(uri: String, cookie: &str, fields: &[(&str, &str)]) -> Request<Body> {
    let boundary = "----machineboundary";
    let mut body = String::new();
    for (name, value) in fields {
        body.push_str(&format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
        ));
    }
    body.push_str(&format!("--{boundary}--\r\n"));
    Request::builder()
        .method("POST")
        .uri(uri)
        .header(header::HOST, "localhost")
        .header(header::ORIGIN, "http://localhost")
        .header("cookie", cookie)
        .header(
            "content-type",
            format!("multipart/form-data; boundary={boundary}"),
        )
        .body(Body::from(body))
        .unwrap()
}

fn done_reply(body: &str) -> String {
    let done = body
        .split("\n\n")
        .find(|b| b.contains("event: done"))
        .expect("done block");
    let data = done.lines().find(|l| l.starts_with("data: ")).unwrap();
    serde_json::from_str::<serde_json::Value>(&data[6..]).unwrap()["content"]
        .as_str()
        .unwrap()
        .to_string()
}

fn bearer_token(reply: &str) -> String {
    reply
        .split("Bearer ")
        .nth(1)
        .and_then(|s| s.split_whitespace().next())
        .expect("token in prompt")
        .to_string()
}

#[tokio::test]
async fn resend_keeps_machine_refs_and_mints_a_fresh_grant() {
    let (app, db, _g) = make_app().await;
    let cookie = login(&app).await;
    let fake = FakeVnc::start(4, 4).await;
    let machine = db
        .create_machine("desktop", "127.0.0.1", fake.port as i64, "sekrit")
        .await
        .unwrap();

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let resp = app
        .clone()
        .oneshot(multipart(
            format!("/api/threads/{tid}/send/stream"),
            &cookie,
            &[
                ("prompt", "reboot it"),
                ("machine_ids", &format!("[{}]", machine.id)),
            ],
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let first_reply = done_reply(&body_str(resp.into_body()).await);
    let first_token = bearer_token(&first_reply);

    // Regenerate the turn from the assistant message: no prompt field, so
    // the stored machine reference is re-resolved and a new grant minted.
    let msgs = db.list_messages(&tid).await.unwrap();
    let assistant = msgs.iter().find(|m| m.role == "assistant").unwrap();
    let resp = app
        .clone()
        .oneshot(multipart(
            format!("/api/threads/{tid}/messages/{}/resend", assistant.id),
            &cookie,
            &[("mode", "code")],
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let reply = done_reply(&body_str(resp.into_body()).await);

    assert!(reply.contains("\"desktop\" (id "), "reply: {reply}");
    assert!(reply.contains("Bearer mc_"), "reply: {reply}");
    assert!(!reply.contains("sekrit"), "reply: {reply}");
    let second_token = bearer_token(&reply);
    assert_ne!(first_token, second_token, "each run gets its own grant");

    // The kept user message still carries the machine chip.
    let msgs = db.list_messages(&tid).await.unwrap();
    let user_msg = msgs.iter().find(|m| m.role == "user").unwrap();
    let atts: serde_json::Value = serde_json::from_str(&user_msg.attachments).unwrap();
    assert_eq!(atts[0]["kind"], "machine");
    assert_eq!(atts[0]["machine_id"], machine.id);

    // Both grants are dead once their runs end.
    for token in [first_token, second_token] {
        let mut status = StatusCode::OK;
        for _ in 0..100 {
            let resp = app
                .clone()
                .oneshot(grant_request(
                    "GET",
                    &format!("/api/machine-control/{}/screenshot", machine.id),
                    &token,
                    "",
                ))
                .await
                .unwrap();
            status = resp.status();
            if status == StatusCode::UNAUTHORIZED {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}
