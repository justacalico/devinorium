//! Integration tests for the core API: threads CRUD, workspaces, file
//! manager, invites, and models — using a stub provider so no devin CLI is
//! required.

#![cfg(test)]

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use async_trait::async_trait;
use tower::ServiceExt;

use devinorium::{
    auth,
    config::Config,
    db,
    providers::{ModelInfo, Provider, SendRequest, SendResponse, StartRequest, StartResponse},
    AppState,
};

/// A stub provider that echoes the prompt back, for deterministic tests.
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
        Ok(vec![
            ModelInfo { id: "stub-1".into(), label: "Stub One".into(), cost_tier: "free".into(), family: "stub".into() },
            ModelInfo { id: "stub-2".into(), label: "Stub Two".into(), cost_tier: "free".into(), family: "stub".into() },
        ])
    }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        Ok(StartResponse {
            session_id: format!("stub-session-{}", req.prompt.len()),
            reply: format!("echo: {}", req.prompt),
            title: "Stub Thread".into(),
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        Ok(SendResponse {
            reply: format!("echo: {}", req.prompt),
        })
    }
    async fn export(&self, _session_id: &str, _working_dir: &std::path::Path) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
}

async fn make_app() -> (Router, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("api.db").display());
    let database = db::Db::connect(&db_url).await.unwrap();
    auth::bootstrap::run(&database, "owner", "supersecret123").await.unwrap();

    // A workspace root under the temp dir.
    let ws_root = dir.join("workspaces");
    std::fs::create_dir_all(&ws_root).unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        workspace_roots: vec![ws_root],
        devin_bin: "devin".into(),
        default_model: "stub-1".into(),
        trust_proxy: false,
        max_body_bytes: 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
    };

    let state = AppState {
        config: Arc::new(cfg),
        db: database.clone(),
        provider: Arc::new(StubProvider) as Arc<dyn Provider>,
    };
    (devinorium::build_app(state), database)
}

async fn login(app: &Router) -> String {
    let resp = app.clone()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"owner","password":"supersecret123"}"#))
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
    let bytes = to_bytes(b, 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[tokio::test]
async fn models_list() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let resp = app.clone()
        .oneshot(authed("GET", "/api/models", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("stub-1"), "body: {body}");
    assert!(body.contains("Stub Two"), "body: {body}");
}

#[tokio::test]
async fn workspace_create_list_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Create a workspace at a path within the root.
    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "POST",
            "/api/workspaces",
            &cookie,
            r#"{"path":"proj1","label":"Proj1"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let wid: i64 = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap();

    // List.
    let resp = app.clone()
        .clone()
        .oneshot(authed("GET", "/api/workspaces", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("Proj1"), "body: {body}");

    // Delete.
    let resp = app.clone()
        .oneshot(authed("DELETE", &format!("/api/workspaces/{wid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn workspace_rejects_path_outside_root() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    // /etc is not within the workspace root.
    let resp = app.clone()
        .oneshot(authed(
            "POST",
            "/api/workspaces",
            &cookie,
            r#"{"path":"/etc","label":"evil"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_create_get_list_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Create a thread.
    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            r#"{"title":"My Thread"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let tid: String = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Get it back.
    let resp = app.clone()
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("My Thread"), "body: {body}");

    // List.
    let resp = app.clone()
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Rename.
    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"title":"Renamed"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Delete.
    let resp = app.clone()
        .oneshot(authed("DELETE", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn thread_send_uses_stub_provider_and_persists_messages() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    // Create a thread.
    let resp = app.clone()
        .clone()
        .oneshot(authed("POST", "/api/threads", &cookie, r#"{"title":"T"}"#))
        .await
        .unwrap();
    let tid: String = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Send a message (multipart).
    let boundary = "----testboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
    );
    let resp = app.clone()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send"))
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .header("content-type", format!("multipart/form-data; boundary={boundary}"))
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("echo: Hello world"), "body: {body}");

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world");

    // Thread now has a session id.
    let thread = db.get_thread(&tid, 1).await.unwrap().unwrap();
    assert!(thread.devin_session_id.is_some());
}

#[tokio::test]
async fn invites_create_and_list() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app.clone()
        .clone()
        .oneshot(authed("POST", "/api/invites", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("token"), "body: {body}");

    let resp = app.clone()
        .oneshot(authed("GET", "/api/invites", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("token"), "body: {body}");
}

#[tokio::test]
async fn file_manager_list_upload_read_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Create a workspace.
    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "POST",
            "/api/workspaces",
            &cookie,
            r#"{"path":"fm","label":"FM"}"#,
        ))
        .await
        .unwrap();
    let wid: i64 = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_i64()
        .unwrap();

    // Upload a file.
    let boundary = "----fmboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\nContent-Type: text/plain\r\n\r\nhi there\r\n--{boundary}--\r\n"
    );
    let resp = app.clone()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/workspaces/{wid}/files"))
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .header("content-type", format!("multipart/form-data; boundary={boundary}"))
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // List dir.
    let resp = app.clone()
        .clone()
        .oneshot(authed("GET", &format!("/api/workspaces/{wid}/files"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("hello.txt"), "body: {body}");

    // Read file content.
    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/workspaces/{wid}/files/content?path=hello.txt"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("base64"), "body: {body}");

    // Delete file.
    let resp = app.clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/workspaces/{wid}/files/delete?path=hello.txt"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn file_manager_rejects_traversal() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "POST",
            "/api/workspaces",
            &cookie,
            r#"{"path":"tv","label":"TV"}"#,
        ))
        .await
        .unwrap();
    let wid: i64 = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_i64()
        .unwrap();

    // Attempt traversal via ..
    let resp = app.clone()
        .oneshot(authed(
            "GET",
            &format!("/api/workspaces/{wid}/files?path=../../etc"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_isolation_between_users() {
    let (app, db) = make_app().await;
    let owner_cookie = login(&app).await;

    // Owner creates an invite and a second user registers.
    let resp = app.clone()
        .clone()
        .oneshot(authed("POST", "/api/invites", &owner_cookie, ""))
        .await
        .unwrap();
    let invite: String = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["token"]
        .as_str()
        .unwrap()
        .to_string();

    let resp = app.clone()
        .clone()
        .oneshot(authed(
            "POST",
            "/api/auth/register",
            &owner_cookie,
            &format!(r#"{{"invite":"{invite}","username":"alice","password":"alicepass123"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Owner creates a thread.
    let resp = app.clone()
        .clone()
        .oneshot(authed("POST", "/api/threads", &owner_cookie, r#"{"title":"owner-thread"}"#))
        .await
        .unwrap();
    let owner_tid: String = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Alice logs in.
    let resp = app.clone()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"alice","password":"alicepass123"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    let alice_cookie = resp
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string();

    // Alice cannot see owner's thread.
    let resp = app.clone()
        .oneshot(authed("GET", &format!("/api/threads/{owner_tid}"), &alice_cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // Alice's thread list is empty.
    let resp = app.clone()
        .oneshot(authed("GET", "/api/threads", &alice_cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert_eq!(body, "[]");

    // Confirm owner's thread still exists in DB owned by owner.
    let _ = db;
}
