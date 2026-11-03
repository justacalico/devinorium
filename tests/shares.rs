//! Integration tests for public thread shares: publishing a thread
//! transcript at `/shared/<id>`, re-sharing, revoking, ownership scoping,
//! and HTML escaping on the public page.

#![cfg(test)]

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use tower::ServiceExt;
use uuid::Uuid;

use async_trait::async_trait;
use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers::{
        MessagePart, ModelInfo, Provider, SendRequest, SendResponse, StartRequest, StartResponse,
    },
    AppState,
};

struct StubProvider;

#[async_trait]
impl Provider for StubProvider {
    fn id(&self) -> &str {
        "stub"
    }
    fn name(&self) -> &str {
        "Stub"
    }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        Ok(vec![ModelInfo {
            id: "stub-1".into(),
            label: "Stub One".into(),
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
        Ok(StartResponse {
            session_id: "s".into(),
            reply: format!("echo: {}", req.prompt),
            thinking: String::new(),
            parts: vec![MessagePart::text(format!("echo: {}", req.prompt))],
            title: "Stub Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        Ok(SendResponse {
            reply: format!("echo: {}", req.prompt),
            thinking: String::new(),
            parts: vec![MessagePart::text(format!("echo: {}", req.prompt))],
            usage: None,
        })
    }
    async fn health_check(&self) -> anyhow::Result<()> {
        Ok(())
    }
}

async fn make_app() -> (Router, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("shares.db").display());
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
        default_model: "stub-1".into(),
        trust_proxy: false,
        max_body_bytes: 20 * 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
        local_token: None,
        tailscale_bin: "tailscale".into(),
        dev_mode: false,
        push_contact: "mailto:test@localhost".into(),
        satellite: false,
        node_name: String::new(),
    };

    let state = AppState {
        config: Arc::new(cfg.clone()),
        db: database.clone(),
        provider: Arc::new(StubProvider) as Arc<dyn Provider>,
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
    let bytes = to_bytes(b, 4 * 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

async fn create_project(app: &Router, cookie: &str) -> i64 {
    let suffix = Uuid::new_v4();
    let body = format!(r#"{{"name":"share-project-{suffix}","path":"share-project-{suffix}"}}"#);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_i64()
        .unwrap()
}

async fn make_thread(app: &Router, cookie: &str, project_id: i64) -> String {
    let body = format!(r#"{{"project_id":{project_id},"title":"share me"}}"#);
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/threads", cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn add_message(db: &db::Db, thread_id: &str, role: &str, content: &str) {
    db.add_message(db::NewMessage {
        thread_id: thread_id.into(),
        role: role.into(),
        content: content.into(),
        thinking: None,
        parts: "[]".into(),
        attachments: "[]".into(),
        model: "m".into(),
        client_message_id: None,
    })
    .await
    .unwrap();
}

async fn public_get(app: &Router, uri: &str) -> (StatusCode, String) {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(uri)
                .header(header::HOST, "localhost")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    (status, body_str(resp.into_body()).await)
}

#[tokio::test]
async fn share_publishes_transcript_at_public_url() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hello there").await;
    add_message(&database, &tid, "assistant", "echo: hello there").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    let share_id = body["share_id"].as_str().expect("share_id on thread");
    assert!(share_id.starts_with("sh-"));

    // The public page needs no session cookie.
    let (status, html) = public_get(&app, &format!("/shared/{share_id}")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("share me"), "title missing: {html}");
    assert!(html.contains("hello there"));
    assert!(html.contains("echo: hello there"));
    assert!(html.contains("Shared conversation"));
}

#[tokio::test]
async fn share_id_shows_up_in_thread_list() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hi").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let share_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(&share_id),
        "list should carry share_id: {body}"
    );
}

#[tokio::test]
async fn share_id_shows_up_in_project_thread_list() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hi").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let share_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/threads"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(&share_id),
        "project thread list should carry share_id: {body}"
    );
}

#[tokio::test]
async fn reshare_keeps_link_and_refreshes_snapshot() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "first").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let first_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    add_message(&database, &tid, "assistant", "second turn").await;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let second_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(first_id, second_id, "re-share must keep the same link");

    let (status, html) = public_get(&app, &format!("/shared/{first_id}")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("second turn"), "snapshot should refresh");
}

#[tokio::test]
async fn unshare_revokes_public_page() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hi").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let share_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert!(body["share_id"].is_null(), "share_id should clear");

    let (status, _) = public_get(&app, &format!("/shared/{share_id}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deleting_thread_removes_share() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hi").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let share_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/threads/{tid}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let (status, _) = public_get(&app, &format!("/shared/{share_id}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn share_requires_auth_and_ownership() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(&database, &tid, "user", "hi").await;

    // No session cookie: the request is rejected before the handler.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/share"))
                .header(header::HOST, "localhost")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(
        matches!(
            resp.status(),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
        ),
        "unauthenticated share must be rejected, got {}",
        resp.status()
    );

    // A different user gets a 404, not the owner's share.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/users",
            &cookie,
            r#"{"username":"mallory","password":"mallorypass123"}"#,
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
                .body(Body::from(
                    r#"{"username":"mallory","password":"mallorypass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let other_cookie = resp
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
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &other_cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // And sharing a thread that does not exist 404s too.
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/threads/nope/share", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn shared_page_escapes_message_content() {
    let (app, database) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid).await;
    add_message(
        &database,
        &tid,
        "user",
        "try **bold** then <script>alert(1)</script> and [x](javascript:alert)",
    )
    .await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/share"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let share_id = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["share_id"]
        .as_str()
        .unwrap()
        .to_string();

    let (status, html) = public_get(&app, &format!("/shared/{share_id}")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!html.contains("<script>alert(1)</script>"), "xss: {html}");
    assert!(
        !html.contains("href=\"javascript"),
        "js link must be dropped: {html}"
    );
    assert!(
        html.contains("<strong>bold</strong>"),
        "markdown should render: {html}"
    );
}

#[tokio::test]
async fn unknown_share_id_is_a_plain_404() {
    let (app, _db) = make_app().await;
    let (status, html) = public_get(&app, "/shared/sh-doesnotexist").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(html.contains("Share not found"));
}
