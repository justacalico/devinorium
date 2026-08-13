//! Integration tests for the core API: threads CRUD, thread groups, file
//! manager, accounts, and models — using a stub provider so no devin CLI is
//! required.

#![cfg(test)]

use std::sync::Arc;

use async_trait::async_trait;
use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use tower::ServiceExt;
use uuid::Uuid;

use devinorium::{
    auth,
    config::Config,
    db,
    providers::{
        ModelInfo, Provider, SendRequest, SendResponse, StartRequest, StartResponse, ToolCallEvent,
    },
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
            ModelInfo {
                id: "stub-1".into(),
                label: "Stub One".into(),
                cost_tier: "free".into(),
                family: "stub".into(),
                cost_summary: "Free".into(),
                max_context_tokens: 200_000,
                max_output_tokens: 32_000,
                is_new: false,
                is_beta: false,
            },
            ModelInfo {
                id: "stub-2".into(),
                label: "Stub Two".into(),
                cost_tier: "free".into(),
                family: "stub".into(),
                cost_summary: "Free".into(),
                max_context_tokens: 200_000,
                max_output_tokens: 32_000,
                is_new: false,
                is_beta: false,
            },
        ])
    }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let reply = format!("echo: {}", req.prompt);
        let thinking = "reasoning about the prompt".to_string();
        if let Some(cb) = &req.options.thinking_callback {
            cb(thinking.clone());
        }
        if let Some(cb) = &req.options.tool_callback {
            cb(ToolCallEvent {
                id: "stub-tool-1".into(),
                title: "Stub tool".into(),
                kind: "execute".into(),
                status: "completed".into(),
                command: Some(format!("echo {}", req.prompt)),
                output: Some("stub output".into()),
                output_preview: Some("stub output".into()),
                changed_files: vec![],
            });
        }
        if let Some(cb) = &req.options.text_callback {
            cb(reply.clone());
        }
        Ok(StartResponse {
            session_id: format!("stub-session-{}", req.prompt.len()),
            reply,
            thinking,
            title: "Stub Thread".into(),
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let reply = format!("echo: {}", req.prompt);
        let thinking = "reasoning about the prompt".to_string();
        if let Some(cb) = &req.options.thinking_callback {
            cb(thinking.clone());
        }
        if let Some(cb) = &req.options.tool_callback {
            cb(ToolCallEvent {
                id: "stub-tool-1".into(),
                title: "Stub tool".into(),
                kind: "execute".into(),
                status: "completed".into(),
                command: Some(format!("echo {}", req.prompt)),
                output: Some("stub output".into()),
                output_preview: Some("stub output".into()),
                changed_files: vec![],
            });
        }
        if let Some(cb) = &req.options.text_callback {
            cb(reply.clone());
        }
        Ok(SendResponse {
            reply,
            thinking,
        })
    }
    async fn export(
        &self,
        _session_id: &str,
        _working_dir: &std::path::Path,
    ) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }

    async fn health_check(&self) -> anyhow::Result<()> {
        Ok(())
    }
}

async fn make_app() -> (Router, db::Db) {
    let dir = tempfile::tempdir().unwrap().keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("api.db").display());
    let database = db::Db::connect(&db_url).await.unwrap();
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .unwrap();

    // Tests use the fallback provider; clear the default command so
    // provider_for_user does not try to spawn the real devin binary.
    sqlx::query("UPDATE users SET provider_command = '' WHERE username = 'owner'")
        .execute(database.pool())
        .await
        .unwrap();

    // A file root under the temp dir.
    let file_root = dir.join("files");
    std::fs::create_dir_all(&file_root).unwrap();

    let cfg = Config {
        host: "127.0.0.1".into(),
        port: 0,
        session_key: b"test-key-test-key-test-key-test-key".to_vec(),
        db_url,
        bootstrap_username: "owner".into(),
        bootstrap_password: "supersecret123".into(),
        file_root: Some(file_root),
        default_model: "stub-1".into(),
        trust_proxy: false,
        max_body_bytes: 20 * 1024 * 1024,
        secure_cookie: false,
        allowed_origin: None,
    };

    let state = AppState {
        config: Arc::new(cfg),
        db: database.clone(),
        provider: Arc::new(StubProvider) as Arc<dyn Provider>,
        pending_permission_requests: Arc::new(tokio::sync::Mutex::new(
            std::collections::HashMap::new(),
        )),
    };
    (devinorium::build_app(state), database)
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

async fn create_user(app: &Router, owner_cookie: &str, username: &str, password: &str) -> i64 {
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/users",
            owner_cookie,
            &format!(r#"{{"username":"{username}","password":"{password}"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap()
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
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "make_thread failed: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
}

#[tokio::test]
async fn models_list() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/models", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("stub-1"), "body: {body}");
    assert!(body.contains("Stub Two"), "body: {body}");
}

#[tokio::test]
async fn thread_create_get_list_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;

    // Create a thread.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"My Thread"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "thread create failed: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let tid: String = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Get it back.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("My Thread"), "body: {body}");

    // List.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Rename.
    let resp = app
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
}

#[tokio::test]
async fn thread_permissions_crud() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    // Create with a permission allowlist.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"permission_mode":"bypass","permissions":"Exec(curl), Fetch(**)"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let tid: String = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        body.contains("Exec(curl)"),
        "created thread should expose permissions: {body}"
    );

    // Update and clear.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"permissions":""}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(
        !body.contains("Exec(curl)"),
        "cleared permissions should not appear: {body}"
    );
}

#[tokio::test]
async fn thread_model_update() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"model":"glm-5-2"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let tid: String = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(body.contains("glm-5-2"), "body: {body}");

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"model":"swe-1-7"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains("swe-1-7"),
        "updated model should persist: {body}"
    );
}

#[tokio::test]
async fn thread_send_uses_stub_provider_and_persists_messages() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    // Send a message (multipart).
    let boundary = "----testboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
    );
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send"))
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
    assert!(body.contains("echo: Hello world"), "body: {body}");
    assert!(body.contains("reasoning about the prompt"), "body: {body}");

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world");
    assert!(msgs[1].thinking.as_ref().is_some_and(|s| s == "reasoning about the prompt"));

    // Thread now has a session id.
    let thread = db.get_thread(&tid, 1).await.unwrap().unwrap();
    assert!(thread.devin_session_id.is_some());
}

#[tokio::test]
async fn thread_send_streams_reply_as_sse() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----streamboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
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
    assert_eq!(
        resp.headers()
            .get("content-type")
            .unwrap()
            .to_str()
            .unwrap(),
        "text/event-stream"
    );

    let body = body_str(resp.into_body()).await;
    assert!(body.contains("event: user_message"), "body: {body}");
    assert!(body.contains("event: thinking"), "body: {body}");
    assert!(body.contains("event: tool_call"), "body: {body}");
    assert!(body.contains("event: chunk"), "body: {body}");
    assert!(body.contains("event: done"), "body: {body}");

    let thinking_pos = body.find("event: thinking").expect("thinking event");
    let tool_call_pos = body.find("event: tool_call").expect("tool_call event");
    let chunk_pos = body.find("event: chunk").expect("chunk event");
    let done_pos = body.find("event: done").expect("done event");
    assert!(thinking_pos < tool_call_pos, "thinking should come before tool_call");
    assert!(tool_call_pos < chunk_pos, "tool_call should come before chunk");
    assert!(chunk_pos < done_pos, "chunk should come before done");

    let tool_call_block = body
        .split("\n\n")
        .find(|b| b.contains("event: tool_call"))
        .expect("tool_call block");
    let tool_call_data = tool_call_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("tool_call data");
    let tool_call_json: serde_json::Value =
        serde_json::from_str(&tool_call_data[6..]).expect("valid tool_call json");
    assert_eq!(tool_call_json["title"], "Stub tool");
    assert_eq!(tool_call_json["kind"], "execute");
    assert_eq!(tool_call_json["status"], "completed");

    let done_block = body
        .split("\n\n")
        .find(|b| b.contains("event: done"))
        .expect("done block");
    let done_data = done_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("done data");
    let done_json: serde_json::Value =
        serde_json::from_str(&done_data[6..]).expect("valid done json");
    assert_eq!(done_json["role"], "assistant");
    assert_eq!(done_json["content"], "echo: Hello world");
    assert_eq!(
        done_json["thinking"].as_str(),
        Some("reasoning about the prompt")
    );

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world");
    assert!(msgs[1].thinking.as_ref().is_some_and(|s| s == "reasoning about the prompt"));
}

#[tokio::test]
async fn accounts_owner_create_and_list() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/users",
            &cookie,
            r#"{"username":"alice","password":"alicepass123"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["username"], "alice");

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/users", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let users = serde_json::from_str::<Vec<serde_json::Value>>(&body).unwrap();
    assert!(users.iter().any(|u| u["username"] == "alice" && u["is_owner"] == false));
}

#[tokio::test]
async fn file_manager_list_upload_read_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Upload a file to the global file root.
    let boundary = "----fmboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\nContent-Type: text/plain\r\n\r\nhi there\r\n--{boundary}--\r\n"
    );
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/files")
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

    // List dir.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/files", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("hello.txt"), "body: {body}");

    // Read file content.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/files/content?path=hello.txt",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("base64"), "body: {body}");

    // Delete file.
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            "/api/files/delete?path=hello.txt",
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

    // Attempt traversal via ..
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/files?path=../../etc", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_group_create_list_rename_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Create a group.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/thread-groups",
            &cookie,
            r#"{"name":"My Group"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let gid: i64 = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_i64()
        .unwrap();

    // List groups.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/thread-groups", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("My Group"), "body: {body}");

    // Rename.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/thread-groups/{gid}"),
            &cookie,
            r#"{"name":"Renamed Group"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify rename.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/thread-groups/{gid}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("Renamed Group"), "body: {body}");

    // Delete.
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/thread-groups/{gid}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn thread_group_with_threads() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;

    // Create two threads.
    let tid_a = make_thread(&app, &cookie, pid, "Thread A").await;
    let tid_b = make_thread(&app, &cookie, pid, "Thread B").await;

    // Create a group and move both threads into it.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/thread-groups",
            &cookie,
            &format!(r#"{{"name":"Group 1","thread_ids":["{tid_a}","{tid_b}"]}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let gid: i64 = serde_json::from_str::<serde_json::Value>(&body_str(resp.into_body()).await)
        .unwrap()["id"]
        .as_i64()
        .unwrap();

    // Verify thread A has the group id.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid_a}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(&format!(r#""thread_group_id":{gid}"#)),
        "body: {body}"
    );

    // Move thread A out of the group (ungroup).
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid_a}"),
            &cookie,
            r#"{"thread_group_id":null}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify thread A is now ungrouped.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid_a}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""thread_group_id":null"#), "body: {body}");

    // Delete the group — thread B should become ungrouped.
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/thread-groups/{gid}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify thread B is now ungrouped.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid_b}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""thread_group_id":null"#), "body: {body}");
}

#[tokio::test]
async fn thread_isolation_between_users() {
    let (app, db) = make_app().await;
    let owner_cookie = login(&app).await;

    // Owner creates a second user.
    create_user(&app, &owner_cookie, "alice", "alicepass123").await;

    // Owner creates a project and a thread.
    let owner_pid = create_project(&app, &owner_cookie).await;
    let owner_tid = make_thread(&app, &owner_cookie, owner_pid, "owner-thread").await;

    // Alice logs in.
    let alice_cookie = login_as(&app, "alice", "alicepass123").await;

    // Alice cannot see owner's thread.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{owner_tid}"),
            &alice_cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // Alice's thread list is empty.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &alice_cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert_eq!(body, "[]");

    let _ = db;
}

#[tokio::test]
async fn thread_rejects_invalid_permission_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let resp = app
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"T","permission_mode":"god-mode"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_accepts_each_valid_permission_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    for mode in &["normal", "accept-edits", "smart", "bypass"] {
        let resp = app
            .clone()
            .oneshot(authed(
                "POST",
                "/api/threads",
                &cookie,
                &format!(r#"{{"project_id":{pid},"title":"T-{mode}","permission_mode":"{mode}"}}"#),
            ))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::CREATED,
            "mode {mode} should be accepted"
        );
    }
}

#[tokio::test]
async fn disabled_user_cannot_access_protected_routes() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    // Owner creates a second user.
    let bob_id = create_user(&app, &cookie, "bob", "bobpass12345").await;

    // Bob logs in.
    let bob_cookie = login_as(&app, "bob", "bobpass12345").await;

    // Bob can access /me initially.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &bob_cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Owner disables bob via the accounts API.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/users/{bob_id}"),
            &cookie,
            r#"{"disabled":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("\"ok\":true"), "body: {body}");

    // Verify in the DB.
    let bob = db.get_user_by_id(bob_id).await.unwrap().unwrap();
    assert!(bob.disabled);

    // Bob's existing session should now be rejected by the middleware.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &bob_cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn send_rejects_oversized_attachment() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    // Build a multipart body with a >8 MiB attachment.
    let boundary = "----bigboundary";
    let big = "x".repeat(9 * 1024 * 1024);
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nhi\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n{big}\r\n--{boundary}--\r\n"
    );
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send"))
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
    assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn send_rejects_empty_prompt() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----emptyboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n   \r\n--{boundary}--\r\n"
    );
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send"))
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
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn provider_list_requires_auth_and_returns_devin_cli() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/providers", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("devin-cli"), "body: {body}");
    assert!(body.contains("Devin CLI"), "body: {body}");
}

#[tokio::test]
async fn me_includes_default_provider() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("provider_id"), "body: {body}");
    assert!(body.contains("devin-cli"), "body: {body}");
}

#[tokio::test]
async fn update_provider_persists_and_validates() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Unknown provider is rejected.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            "/api/auth/me",
            &cookie,
            r#"{"provider_id":"not-real","provider_command":"devin"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Valid provider is accepted.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            "/api/auth/me",
            &cookie,
            r#"{"provider_id":"devin-cli","provider_command":"devin"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""provider_id":"devin-cli""#), "body: {body}");

    // Confirm it actually persisted.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""provider_id":"devin-cli""#), "body: {body}");
}

#[tokio::test]
async fn provider_health_rejects_invalid_input() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    // Missing command.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/providers/health",
            &cookie,
            r#"{"provider_id":"devin-cli"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Unknown provider.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/providers/health",
            &cookie,
            r#"{"provider_id":"not-real","command":"devin"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn provider_health_fails_for_missing_binary() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/providers/health",
            &cookie,
            r#"{"provider_id":"devin-cli","command":"/nonexistent/devin"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn custom_provider_command_is_used() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "test").await;

    // Set a non-existent command; the provider should try to use it and fail.
    sqlx::query(
        "UPDATE users SET provider_command = '/nonexistent/devin' WHERE username = 'owner'",
    )
    .execute(db.pool())
    .await
    .unwrap();

    let boundary = "----testboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello\r\n--{boundary}--\r\n"
    );
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{id}/send"))
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
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}
