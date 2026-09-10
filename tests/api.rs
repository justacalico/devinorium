//! Integration tests for the core API: threads CRUD, thread groups, file
//! manager, accounts, and models — using a stub provider so no devin CLI is
//! required.

#![cfg(test)]

use std::os::unix::fs::PermissionsExt;
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
    git::{GitRemoteService, GitService},
    plan::{Plan, PlanStep},
    providers::{
        MessagePart, ModelInfo, PartEvent, Provider, SendRequest, SendResponse, StartRequest,
        StartResponse, ToolCallEvent,
    },
    AppState,
};

/// A stub provider that echoes the prompt back, for deterministic tests.
/// `delay_ms` sleeps before returning, letting tests simulate long runs.
struct StubProvider {
    delay_ms: u64,
}

/// Resolves when the cancellation flag is set.
async fn wait_cancelled(flag: std::sync::Arc<std::sync::atomic::AtomicBool>) {
    while !flag.load(std::sync::atomic::Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

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
                default_reasoning_effort: None,
                supported_reasoning_efforts: vec![],
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
                default_reasoning_effort: None,
                supported_reasoning_efforts: vec![],
            },
        ])
    }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        if self.delay_ms > 0 {
            let dur = std::time::Duration::from_millis(self.delay_ms);
            if let Some(ref cancel) = req.options.cancel_signal {
                let cancelled = tokio::select! {
                    _ = tokio::time::sleep(dur) => false,
                    _ = wait_cancelled(cancel.clone()) => true,
                };
                if cancelled {
                    anyhow::bail!("stopped by user");
                }
            } else {
                tokio::time::sleep(dur).await;
            }
        }
        let session_id = format!("stub-session-{}", req.prompt.len());
        if let Some(cb) = &req.options.session_callback {
            cb(session_id.clone()).await;
        }
        let mode = req.options.interaction_mode.clone();
        let reply = format!("echo: {} ({})", req.prompt, mode);
        let thinking = format!("reasoning about the prompt in {mode} mode");
        let parts = vec![
            MessagePart::thinking(thinking.clone()),
            MessagePart::tool_call(ToolCallEvent {
                id: "stub-tool-1".into(),
                title: "Stub tool".into(),
                kind: "execute".into(),
                status: "completed".into(),
                command: Some(format!("echo {}", req.prompt)),
                output: Some("stub output".into()),
                output_preview: Some("stub output".into()),
                changed_files: vec![],
                diffs: vec![],
            }),
            MessagePart::text(reply.clone()),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        Ok(StartResponse {
            session_id,
            reply,
            thinking,
            parts,
            title: "Stub Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        if self.delay_ms > 0 {
            let dur = std::time::Duration::from_millis(self.delay_ms);
            if let Some(ref cancel) = req.options.cancel_signal {
                let cancelled = tokio::select! {
                    _ = tokio::time::sleep(dur) => false,
                    _ = wait_cancelled(cancel.clone()) => true,
                };
                if cancelled {
                    anyhow::bail!("stopped by user");
                }
            } else {
                tokio::time::sleep(dur).await;
            }
        }
        let mode = req.options.interaction_mode.clone();
        let reply = format!("echo: {} ({})", req.prompt, mode);
        let thinking = format!("reasoning about the prompt in {mode} mode");
        let parts = vec![
            MessagePart::thinking(thinking.clone()),
            MessagePart::tool_call(ToolCallEvent {
                id: "stub-tool-1".into(),
                title: "Stub tool".into(),
                kind: "execute".into(),
                status: "completed".into(),
                command: Some(format!("echo {}", req.prompt)),
                output: Some("stub output".into()),
                output_preview: Some("stub output".into()),
                changed_files: vec![],
                diffs: vec![],
            }),
            MessagePart::text(reply.clone()),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        Ok(SendResponse {
            reply,
            thinking,
            parts,
            usage: None,
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

/// A stub provider that replies with a GitLab merge request URL so the
/// automatic link path can be exercised end-to-end.
struct LinkingStubProvider;

#[async_trait]
impl Provider for LinkingStubProvider {
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
    async fn start(&self, _req: StartRequest) -> anyhow::Result<StartResponse> {
        let reply = "Done: https://gitlab.example.com/group/project/-/merge_requests/42";
        let parts = vec![MessagePart::text(reply)];
        Ok(StartResponse {
            session_id: "linking-session".into(),
            reply: reply.into(),
            thinking: "".into(),
            parts,
            title: "Linking Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, _req: SendRequest) -> anyhow::Result<SendResponse> {
        let reply = "Done: https://gitlab.example.com/group/project/-/merge_requests/42";
        let parts = vec![MessagePart::text(reply)];
        Ok(SendResponse {
            reply: reply.into(),
            thinking: "".into(),
            parts,
            usage: None,
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

/// A provider that emits parts incrementally with delays so a stop
/// mid-generation leaves partial output in the run state.
struct StreamingStubProvider;

#[async_trait]
impl Provider for StreamingStubProvider {
    fn id(&self) -> &str {
        "streaming-stub"
    }
    fn name(&self) -> &str {
        "Streaming Stub"
    }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        Ok(vec![ModelInfo {
            id: "streaming-1".into(),
            label: "Streaming One".into(),
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
        let parts = vec![
            MessagePart::thinking("thinking about it"),
            MessagePart::text("partial reply"),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
        // Wait until cancelled, then return the partial parts.
        if let Some(ref cancel) = req.options.cancel_signal {
            while !cancel.load(std::sync::atomic::Ordering::SeqCst) {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        } else {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }
        Ok(StartResponse {
            session_id: "streaming-session".into(),
            reply: "partial reply".into(),
            thinking: "thinking about it".into(),
            parts,
            title: "Streaming Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let parts = vec![
            MessagePart::thinking("thinking about it"),
            MessagePart::text("partial reply"),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
        if let Some(ref cancel) = req.options.cancel_signal {
            while !cancel.load(std::sync::atomic::Ordering::SeqCst) {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        } else {
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }
        Ok(SendResponse {
            reply: "partial reply".into(),
            thinking: "thinking about it".into(),
            parts,
            usage: None,
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

/// A provider that emits a partial response and then fails, simulating a
/// provider crash or rate-limit mid-generation.
struct FailingProvider;

#[async_trait]
impl Provider for FailingProvider {
    fn id(&self) -> &str {
        "failing-stub"
    }
    fn name(&self) -> &str {
        "Failing Stub"
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
        if let Some(cb) = &req.options.session_callback {
            cb(format!("failing-session-{}", req.prompt.chars().count())).await;
        }
        let parts = vec![
            MessagePart::thinking("thinking about it"),
            MessagePart::text("partial reply"),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        anyhow::bail!("provider crashed")
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let parts = vec![
            MessagePart::thinking("thinking about it"),
            MessagePart::text("partial reply"),
        ];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        anyhow::bail!("provider crashed")
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

async fn app_state() -> (AppState, db::Db) {
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

    // A home directory under the temp dir.
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
    };

    let state = AppState {
        config: Arc::new(cfg.clone()),
        db: database.clone(),
        provider: Arc::new(StubProvider { delay_ms: 0 }) as Arc<dyn Provider>,
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
    (state, database)
}

async fn make_app() -> (Router, db::Db) {
    let (state, database) = app_state().await;
    (devinorium::build_app(state), database)
}

/// Seed a batch of messages for a thread in a single transaction so the tests
/// do not pay the cost of a separate SQLite fsync for every insert.
async fn seed_messages(db: &db::Db, thread_id: &str, count: usize, content_prefix: &str) {
    let mut conn = db.pool().acquire().await.expect("acquire db connection");
    sqlx::query("BEGIN")
        .execute(&mut *conn)
        .await
        .expect("begin transaction");

    for i in 0..count {
        let role = if i % 2 == 0 { "user" } else { "assistant" };
        let turn_id = (i / 2 + 1) as i64;
        sqlx::query(
            "INSERT INTO messages (thread_id, role, content, thinking, parts, attachments, model, turn_id, seq)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(thread_id)
        .bind(role)
        .bind(format!("{content_prefix}{i}"))
        .bind::<Option<String>>(None)
        .bind("[]")
        .bind("[]")
        .bind("")
        .bind(turn_id)
        .bind((i + 1) as i64)
        .execute(&mut *conn)
        .await
        .expect("insert message");
    }

    sqlx::query("COMMIT")
        .execute(&mut *conn)
        .await
        .expect("commit transaction");

    if count >= 1000 {
        let _ = sqlx::query("PRAGMA wal_checkpoint(PASSIVE)")
            .execute(&mut *conn)
            .await;
    }
}

async fn make_app_with_delay(delay_ms: u64) -> (Router, db::Db) {
    let (mut state, database) = app_state().await;
    state.provider = Arc::new(StubProvider { delay_ms }) as Arc<dyn Provider>;
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

/// Poll `GET /api/threads/{tid}/run` until `pred` matches the response body.
/// Runs are registered asynchronously once the send request reaches the
/// runner, so fixed sleeps can lose the race on a slow or loaded machine.
/// Panics after ~10s with the last observed body instead of letting a later
/// assertion fail on a stale state.
async fn wait_for_run(
    app: &Router,
    cookie: &str,
    tid: &str,
    pred: impl Fn(&str) -> bool,
) -> String {
    let mut body = String::new();
    for _ in 0..200 {
        let resp = app
            .clone()
            .oneshot(authed(
                "GET",
                &format!("/api/threads/{tid}/run"),
                cookie,
                "",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        body = body_str(resp.into_body()).await;
        if pred(&body) {
            return body;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("run for thread {tid} never reached the expected state; last body: {body}");
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
    let body = body_str(resp.into_body()).await;
    assert!(
        !body.contains("\"tags\""),
        "list should not include tags: {body}"
    );

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
async fn thread_reasoning_effort_round_trips() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"model":"gpt-test","reasoning_effort":"high"}}"#),
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
        body.contains(r#""reasoning_effort":"high""#),
        "created thread should carry the effort: {body}"
    );

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"reasoning_effort":"low"}"#,
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
        body.contains(r#""reasoning_effort":"low""#),
        "updated effort should persist: {body}"
    );

    // An empty string clears the stored effort.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"reasoning_effort":""}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(r#""reasoning_effort":""#),
        "cleared effort should persist: {body}"
    );
}

#[tokio::test]
async fn assistant_message_inherits_updated_model() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

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

    let boundary = "----modelboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello\r\n--{boundary}--\r\n"
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

    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].model, "swe-1-7");
}

#[tokio::test]
async fn thread_pin_success_and_sorts_first() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let tid_a = make_thread(&app, &cookie, pid, "Thread A").await;
    // Give the first thread a message so creating the second one does not
    // delete the empty draft.
    seed_messages(&db, &tid_a, 1, "msg-a").await;
    let _tid_b = make_thread(&app, &cookie, pid, "Thread B").await;

    // Pin the first thread.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid_a}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // The thread detail reflects the pin.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid_a}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""pinned":true"#), "body: {body}");

    // Listing all threads puts the pinned one first.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    assert_eq!(list.len(), 2);
    assert!(list[0]["pinned"].as_bool().unwrap());
    assert_eq!(list[0]["id"].as_str().unwrap(), tid_a);

    // Listing the project's threads also puts the pinned one first.
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
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    assert!(list[0]["pinned"].as_bool().unwrap());
    assert_eq!(list[0]["id"].as_str().unwrap(), tid_a);
}

#[tokio::test]
async fn thread_unpin_success() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/pin"),
            &cookie,
            r#"{"pinned":false}"#,
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
    assert!(body.contains(r#""pinned":false"#), "body: {body}");
}

#[tokio::test]
async fn thread_no_op_pin_does_not_update_updated_at() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let first = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let body = body_str(first.into_body()).await;
    let first_v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let first_updated = first_v["updated_at"].as_str().unwrap();

    let second = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
    let body = body_str(second.into_body()).await;
    let second_v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let second_updated = second_v["updated_at"].as_str().unwrap();

    assert_eq!(first_updated, second_updated);
}

#[tokio::test]
async fn thread_pin_is_isolated_between_users() {
    let (app, _db) = make_app().await;
    let owner_cookie = login(&app).await;
    create_user(&app, &owner_cookie, "alice", "alicepass123").await;
    let pid = create_project(&app, &owner_cookie).await;
    let tid = make_thread(&app, &owner_cookie, pid, "T").await;

    let alice_cookie = login_as(&app, "alice", "alicepass123").await;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/pin"),
            &alice_cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
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
    assert!(body.contains("echo: Hello world (code)"), "body: {body}");
    assert!(
        body.contains("reasoning about the prompt in code mode"),
        "body: {body}"
    );

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world (code)");
    assert_eq!(
        msgs[1].model, "stub-1",
        "assistant message should store thread model"
    );
    assert!(msgs[1]
        .thinking
        .as_ref()
        .is_some_and(|s| s == "reasoning about the prompt in code mode"));

    // Thread now has a session id.
    let thread = db.get_thread(&tid, 1).await.unwrap().unwrap();
    assert!(thread.devin_session_id.is_some());
}

#[tokio::test]
async fn thread_send_persists_partial_output_on_provider_error() {
    let (app, db) = make_app_with_provider(Arc::new(FailingProvider) as Arc<dyn Provider>).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "F").await;

    let boundary = "----failboundary";
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
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);

    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(
        msgs.len(),
        3,
        "expected user, partial assistant, and error messages"
    );
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "partial reply");
    assert!(msgs[1]
        .thinking
        .as_ref()
        .is_some_and(|s| s == "thinking about it"));
    assert_eq!(msgs[2].role, "error");
    assert!(msgs[2].content.contains("provider crashed"));

    let thread = db.get_thread(&tid, 1).await.unwrap().unwrap();
    assert_eq!(
        thread.devin_session_id.as_deref(),
        Some("failing-session-11"),
        "session id should be persisted before prompt fails"
    );
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
    assert!(body.contains("event: part"), "body: {body}");
    assert!(body.contains("event: done"), "body: {body}");

    let part_positions: Vec<usize> = body.match_indices("event: part").map(|(i, _)| i).collect();
    assert_eq!(part_positions.len(), 3, "expected three part events");
    let done_pos = body.find("event: done").expect("done event");
    assert!(
        part_positions.last().unwrap() < &done_pos,
        "parts should come before done"
    );

    let part_blocks = body
        .split("\n\n")
        .filter(|b| b.contains("event: part"))
        .collect::<Vec<_>>();
    assert_eq!(part_blocks.len(), 3);
    let part_types: Vec<String> = part_blocks
        .iter()
        .map(|b| {
            let data = b
                .lines()
                .find(|l| l.starts_with("data: "))
                .expect("part data");
            let json: serde_json::Value =
                serde_json::from_str(&data[6..]).expect("valid part json");
            json["type"].as_str().unwrap_or("").to_string()
        })
        .collect();
    assert_eq!(part_types, vec!["thinking", "tool_call", "text"]);

    let tool_call_block = part_blocks
        .iter()
        .find(|b| b.contains("\"type\":\"tool_call"))
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
    assert_eq!(done_json["content"], "echo: Hello world (code)");
    assert_eq!(done_json["model"], "stub-1");
    assert_eq!(
        done_json["thinking"].as_str(),
        Some("reasoning about the prompt in code mode")
    );

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world (code)");
    assert_eq!(msgs[1].model, "stub-1");
    assert!(msgs[1]
        .thinking
        .as_ref()
        .is_some_and(|s| s == "reasoning about the prompt in code mode"));
}

#[tokio::test]
async fn thread_send_stream_echoes_client_message_id() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----clientidboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}\r\n\
        Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
        cm-abc-123\r\n\
        --{boundary}--\r\n"
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
    let user_block = body
        .split("\n\n")
        .find(|b| b.contains("event: user_message"))
        .expect("user_message block");
    let user_data = user_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("user_message data");
    let user_json: serde_json::Value =
        serde_json::from_str(&user_data[6..]).expect("valid user json");
    assert_eq!(user_json["role"], "user");
    assert_eq!(user_json["client_message_id"], "cm-abc-123");

    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].client_message_id.as_deref(), Some("cm-abc-123"));
}

#[tokio::test]
async fn thread_send_includes_client_message_id() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----clientidboundary2";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}\r\n\
        Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
        cm-abc-456\r\n\
        --{boundary}--\r\n"
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
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["user_message"]["client_message_id"], "cm-abc-456");
    assert_eq!(json["assistant_message"]["role"], "assistant");
}

#[tokio::test]
async fn thread_send_rejects_duplicate_client_message_id() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let (boundary, body) = {
        let boundary = "----dupboundary";
        let client_id = "cm-dup-1";
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            Hello world\r\n\
            --{boundary}\r\n\
            Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
            {client_id}\r\n\
            --{boundary}--\r\n"
        );
        (boundary.to_string(), body)
    };
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

    let (boundary, body) = {
        let boundary = "----dupboundary";
        let client_id = "cm-dup-1";
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            Hello world\r\n\
            --{boundary}\r\n\
            Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
            {client_id}\r\n\
            --{boundary}--\r\n"
        );
        (boundary.to_string(), body)
    };
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
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn thread_send_stream_rejects_duplicate_client_message_id() {
    let (app, _db) = make_app_with_delay(5000).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    fn send_body(client_id: &str) -> (String, String) {
        let boundary = "----dupstreamboundary";
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            Hello world\r\n\
            --{boundary}\r\n\
            Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
            {client_id}\r\n\
            --{boundary}--\r\n"
        );
        (boundary.to_string(), body)
    }

    let (boundary, body) = send_body("cm-stream-dup-1");
    let first = app
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
    assert_eq!(first.status(), StatusCode::OK);

    // Wait for the first run to be registered so the duplicate is rejected.
    wait_for_run(&app, &cookie, &tid, |b| b.contains(r#""status":"running""#)).await;

    let (boundary, body) = send_body("cm-stream-dup-1");
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
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn thread_send_rolls_back_user_message_on_already_running() {
    let (app, db) = make_app_with_delay(5000).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let first_cookie = cookie.clone();
    let first_tid = tid.clone();
    let first_app = app.clone();
    let first = tokio::spawn(async move {
        let boundary = "----firstboundary";
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            First\r\n\
            --{boundary}--\r\n"
        );
        first_app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/threads/{first_tid}/send"))
                    .header(header::HOST, "localhost")
                    .header(header::ORIGIN, "http://localhost")
                    .header("cookie", &first_cookie)
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
    });

    // Wait for the first run to start and persist its user message.
    wait_for_run(&app, &cookie, &tid, |b| b.contains(r#""status":"running""#)).await;

    let boundary = "----secondboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Second\r\n\
        --{boundary}--\r\n"
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
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    // Only the first user message should be persisted; the second was rolled back.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].content, "First");

    first.abort();
}

#[tokio::test]
async fn thread_send_stream_rolls_back_user_message_on_already_running() {
    let (app, db) = make_app_with_delay(5000).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let first_cookie = cookie.clone();
    let first_tid = tid.clone();
    let first_app = app.clone();
    let first = tokio::spawn(async move {
        let boundary = "----firststreamboundary";
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            First stream\r\n\
            --{boundary}--\r\n"
        );
        first_app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/threads/{first_tid}/send/stream"))
                    .header(header::HOST, "localhost")
                    .header(header::ORIGIN, "http://localhost")
                    .header("cookie", &first_cookie)
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
    });

    // Wait for the first stream to start and persist its user message.
    wait_for_run(&app, &cookie, &tid, |b| b.contains(r#""status":"running""#)).await;

    let boundary = "----secondstreamboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Second stream\r\n\
        --{boundary}--\r\n"
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
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    // Only the first user message should be persisted; the second was rolled back.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].content, "First stream");

    first.abort();
}

#[tokio::test]
async fn thread_stop_ends_active_run() {
    let (app, _db) = make_app_with_delay(5000).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----stopboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
    );

    let send_app = app.clone();
    let send_cookie = cookie.clone();
    let send_tid = tid.clone();
    let send_body = body.clone();
    let send_boundary = boundary.to_string();
    let send_task = tokio::spawn(async move {
        send_app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/threads/{send_tid}/send"))
                    .header(header::HOST, "localhost")
                    .header(header::ORIGIN, "http://localhost")
                    .header("cookie", &send_cookie)
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={send_boundary}"),
                    )
                    .body(Body::from(send_body))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    // Wait for the run to start.
    wait_for_run(&app, &cookie, &tid, |b| b.contains(r#""status":"running""#)).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/stop"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""status":"stopped""#), "body: {body}");

    let resp = send_task.await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""stopped":true"#), "body: {body}");

    // The thread should still show a stopped run for a while.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/run"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""status":"stopped""#), "body: {body}");

    // No assistant message should have been persisted.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""role":"user""#), "body: {body}");
    assert!(!body.contains(r#""role":"assistant""#), "body: {body}");
}

#[tokio::test]
async fn thread_stop_persists_partial_output() {
    let (mut state, database) = app_state().await;
    state.provider = Arc::new(StreamingStubProvider) as Arc<dyn Provider>;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----stopboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
    );

    let send_app = app.clone();
    let send_cookie = cookie.clone();
    let send_tid = tid.clone();
    let send_body = body.clone();
    let send_boundary = boundary.to_string();
    let _send_task = tokio::spawn(async move {
        send_app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/threads/{send_tid}/send"))
                    .header(header::HOST, "localhost")
                    .header(header::ORIGIN, "http://localhost")
                    .header("cookie", &send_cookie)
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={send_boundary}"),
                    )
                    .body(Body::from(send_body))
                    .unwrap(),
            )
            .await
            .unwrap()
    });

    // Wait for parts to appear in the run state.
    wait_for_run(&app, &cookie, &tid, |b| b.contains("partial reply")).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/threads/{tid}/stop"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // The partial assistant message is persisted asynchronously after
    // the provider returns from graceful cancellation. Poll for it.
    let mut found = false;
    for _ in 0..200 {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let resp = app
            .clone()
            .oneshot(authed(
                "GET",
                &format!("/api/threads/{tid}/messages"),
                &cookie,
                "",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_str(resp.into_body()).await;
        if body.contains(r#""role":"assistant""#) && body.contains("partial reply") {
            assert!(body.contains(r#""role":"user""#), "body: {body}");
            assert!(body.contains("thinking about it"), "body: {body}");
            found = true;
            break;
        }
    }
    assert!(
        found,
        "partial assistant message was not persisted after stop"
    );

    drop(database);
}

#[tokio::test]
async fn thread_send_stream_uses_interaction_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----modeboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nplan\r\n--{boundary}--\r\n"
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
    assert_eq!(done_json["content"], "echo: Hello world (plan)");
}

#[tokio::test]
async fn thread_send_stream_defaults_interaction_mode_to_code() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----modeboundary";
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

    let body = body_str(resp.into_body()).await;
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
    assert_eq!(done_json["content"], "echo: Hello world (code)");
}

#[tokio::test]
async fn thread_send_stream_normalizes_unknown_interaction_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----modeboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nunknown\r\n--{boundary}--\r\n"
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
    assert_eq!(done_json["content"], "echo: Hello world (code)");
}

#[tokio::test]
async fn thread_runs_in_backend_with_zero_frontends() {
    let (app, db) = make_app_with_delay(300).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----zeroboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello world\r\n--{boundary}--\r\n"
    );

    // Start a stream but immediately drop the response without reading the
    // body, simulating a client that closes the app.
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
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "send/stream should start a run"
    );

    // Poll the run status until it completes or times out.
    let mut status = String::new();
    for _ in 0..50 {
        let resp = app
            .clone()
            .oneshot(authed(
                "GET",
                &format!("/api/threads/{tid}/run"),
                &cookie,
                "",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_str(resp.into_body()).await;
        let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
        status = v["status"].as_str().unwrap_or("idle").to_string();
        if status == "completed" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(
        status, "completed",
        "run should complete without a frontend"
    );

    // Verify messages persisted in DB.
    let msgs = db.list_messages(&tid).await.unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].content, "Hello world");
    assert_eq!(msgs[1].role, "assistant");
    assert_eq!(msgs[1].content, "echo: Hello world (code)");
}

#[tokio::test]
async fn thread_run_snapshot_includes_accumulated_output() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----snapshotboundary";
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

    // Collect the stream so the run completes and the snapshot is populated.
    let _ = to_bytes(resp.into_body(), 100_000).await.unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/run"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["status"], "completed");
    assert!(
        v["text"].as_str().is_some_and(|s| !s.is_empty()),
        "snapshot should include accumulated text"
    );
    assert!(
        v["thinking"].as_str().is_some_and(|s| !s.is_empty()),
        "snapshot should include accumulated thinking"
    );
    assert_eq!(v["thinking_active"], false);
    assert_eq!(v["tool_calls"].as_array().unwrap().len(), 1);
    assert_eq!(v["parts"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn thread_events_can_be_resumed_by_reconnecting_client() {
    let (app, _db) = make_app_with_delay(100).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----reconnectboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello\r\n--{boundary}--\r\n"
    );

    // Start a stream and immediately drop it.
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

    // Subscribe to the active run's events before it completes.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/events"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Collect the SSE events from the response stream.
    let events = to_bytes(resp.into_body(), 10_000).await.unwrap();
    let text = String::from_utf8_lossy(&events);
    assert!(
        text.contains("event: state"),
        "reconnected client should first receive the current run state"
    );
    assert!(
        text.contains("event: done"),
        "reconnected client should receive the done event"
    );

    // The state event should contain the accumulated snapshot.
    let state_block = text
        .split("\n\n")
        .find(|b| b.contains("event: state"))
        .expect("state block");
    let state_data = state_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("state data");
    let state_json: serde_json::Value =
        serde_json::from_str(&state_data[6..]).expect("valid state json");
    assert_eq!(state_json["status"], "running");
    assert!(
        state_json["parts"].is_array(),
        "state should include the parts array"
    );
}

#[tokio::test]
async fn thread_events_seeds_terminal_state_after_run_completes() {
    let (app, _db) = make_app_with_delay(100).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let boundary = "----terminalboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello\r\n--{boundary}--\r\n"
    );

    // Start and fully collect the stream so the run finishes.
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
    let _ = to_bytes(resp.into_body(), 100_000).await.unwrap();

    // Reconnect to the completed run.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/events"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let events = to_bytes(resp.into_body(), 10_000).await.unwrap();
    let text = String::from_utf8_lossy(&events);
    let state_block = text
        .split("\n\n")
        .find(|b| b.contains("event: state"))
        .expect("state block");
    let state_data = state_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("state data");
    let state_json: serde_json::Value =
        serde_json::from_str(&state_data[6..]).expect("valid state json");
    assert_eq!(state_json["status"], "completed");
    assert!(
        state_json["text"].as_str().is_some_and(|s| !s.is_empty()),
        "terminal state should include accumulated text"
    );
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
    assert!(users
        .iter()
        .any(|u| u["username"] == "alice" && u["is_owner"] == false));
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
async fn file_manager_list_paginates() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let body = r#"{"name":"files","path":"files-dir"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let pid = v["id"].as_i64().unwrap();
    let path = v["path"].as_str().unwrap();

    std::fs::create_dir_all(path).unwrap();
    for i in 0..3 {
        std::fs::write(format!("{path}/file{i}.txt"), "x").unwrap();
    }

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={pid}&path=.&limit=2&offset=0"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 2);

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={pid}&path=.&limit=2&offset=2"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn file_manager_includes_git_status() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/projects",
            &cookie,
            r#"{"name":"git-status","path":"git-status"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let pid = v["id"].as_i64().unwrap();
    let path = v["path"].as_str().unwrap();

    std::fs::create_dir_all(path).unwrap();
    std::fs::write(format!("{path}/tracked.txt"), "tracked").unwrap();
    std::fs::create_dir_all(format!("{path}/sub")).unwrap();
    std::fs::write(format!("{path}/sub/nested.txt"), "nested").unwrap();

    let run_git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .current_dir(path)
            .args(args)
            .output()
            .expect("git command");
        assert!(out.status.success(), "git {args:?} failed: {out:?}");
    };
    run_git(&["init", "-q"]);
    run_git(&["config", "user.email", "test@example.com"]);
    run_git(&["config", "user.name", "Test"]);
    run_git(&["add", "."]);
    run_git(&["commit", "-q", "-m", "init"]);

    // Modify tracked, delete tracked, add new, and modify nested.
    std::fs::write(format!("{path}/tracked.txt"), "changed").unwrap();
    std::fs::remove_file(format!("{path}/tracked.txt")).unwrap();
    std::fs::write(format!("{path}/new.txt"), "new").unwrap();
    std::fs::write(format!("{path}/sub/nested.txt"), "changed").unwrap();

    let find_in = |body: &str, name: &str| {
        let entries: Vec<serde_json::Value> = serde_json::from_str(body).unwrap();
        entries
            .into_iter()
            .find(|e| e["name"].as_str() == Some(name))
            .map(|e| e["git_status"].clone())
    };

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={pid}&path=."),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;

    assert_eq!(find_in(&body, "new.txt"), Some("untracked".into()));
    assert_eq!(find_in(&body, "sub"), Some("descendant".into()));
    // tracked.txt was deleted and removed from disk, so it is not in the listing.
    assert_eq!(find_in(&body, "tracked.txt"), None);

    // Listing a subdirectory should map statuses relative to that path.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={pid}&path=sub"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert_eq!(find_in(&body, "nested.txt"), Some("modified".into()));
}

#[tokio::test]
async fn file_manager_read_returns_git_diff_when_requested() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/projects",
            &cookie,
            r#"{"name":"git-diff","path":"git-diff"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let pid = v["id"].as_i64().unwrap();
    let path = v["path"].as_str().unwrap();

    std::fs::create_dir_all(path).unwrap();
    std::fs::write(format!("{path}/hello.txt"), "hello\n").unwrap();

    let run_git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .current_dir(path)
            .args(args)
            .output()
            .expect("git command");
        assert!(out.status.success(), "git {args:?} failed: {out:?}");
    };
    run_git(&["init", "-q"]);
    run_git(&["config", "user.email", "test@example.com"]);
    run_git(&["config", "user.name", "Test"]);
    run_git(&["add", "."]);
    run_git(&["commit", "-q", "-m", "init"]);

    std::fs::write(format!("{path}/hello.txt"), "world\n").unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files/content?project_id={pid}&path=hello.txt&diff=true"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(
        v["text"],
        serde_json::Value::Null,
        "text should be omitted when diff is present"
    );
    assert_eq!(v["diff"]["old_text"], "hello\n");
    assert_eq!(v["diff"]["new_text"], "world\n");

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files/content?project_id={pid}&path=hello.txt"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v.get("diff").is_none() || v["diff"].is_null());
    assert_eq!(v["text"], "world\n");
}

#[tokio::test]
async fn file_manager_write_replaces_and_detects_conflicts() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/projects",
            &cookie,
            r#"{"name":"write","path":"write"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let pid = v["id"].as_i64().unwrap();
    let path = v["path"].as_str().unwrap();
    std::fs::create_dir_all(path).unwrap();
    std::fs::write(format!("{path}/hello.txt"), "hello\n").unwrap();

    // Read the initial content and capture its hash.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files/content?project_id={pid}&path=hello.txt"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let initial = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let original_hash = initial["sha256"].as_str().unwrap();
    assert!(!original_hash.is_empty());
    assert_eq!(initial["text"], "hello\n");

    // Write with the correct expected hash.
    let write_body = format!(
        r#"{{"path":"hello.txt","project_id":{pid},"content":"world\n","expected_sha256":"{original_hash}"}}"#,
    );
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/files/content", &cookie, &write_body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let updated = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(updated["text"], "world\n");
    assert_ne!(updated["sha256"].as_str().unwrap(), original_hash);

    // Re-read to confirm the file changed.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files/content?project_id={pid}&path=hello.txt"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["text"], "world\n");

    // Write with the stale hash; should conflict.
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/files/content",
            &cookie,
            &format!(
                r#"{{"path":"hello.txt","project_id":{pid},"content":"stale\n","expected_sha256":"{original_hash}"}}"#
            ),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    let conflict = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(conflict["error"], "file changed on disk");
    assert_eq!(conflict["current"]["text"], "world\n");

    // Write a new file without an expected hash.
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/files/content",
            &cookie,
            &format!(r#"{{"path":"new.txt","project_id":{pid},"content":"new file\n"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["text"], "new file\n");
    assert!(std::path::Path::new(&format!("{path}/new.txt")).exists());
}

#[tokio::test]
async fn file_manager_omits_git_status_outside_git_repo() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/projects",
            &cookie,
            r#"{"name":"nogit","path":"nogit"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let pid = v["id"].as_i64().unwrap();
    let path = v["path"].as_str().unwrap();
    std::fs::write(format!("{path}/readme.txt"), "hi").unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?project_id={pid}&path=."),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let entries: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    for e in entries {
        assert!(e.get("git_status").is_none());
    }
}

#[tokio::test]
async fn project_accepts_absolute_path_with_spaces() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let outside = tempfile::tempdir().unwrap().keep();
    let project_path = outside.join("my drive").join("my app");

    let body = format!(r#"{{"name":"spaced","path":"{}"}}"#, project_path.display());
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["path"].as_str().unwrap().contains("my drive"));
    assert!(v["path"].as_str().unwrap().contains("my app"));
}

#[tokio::test]
async fn project_accepts_existing_home_subdir() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    // Create a subdir inside the configured home dir before creating the project.
    let sub = home.join("devinorium");
    std::fs::create_dir_all(&sub).unwrap();

    let body = r#"{"name":"devin","path":"devinorium"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
}

#[tokio::test]
async fn project_accepts_tilde_subdir() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let sub = home.join("devin");
    std::fs::create_dir_all(&sub).unwrap();

    let body = r#"{"name":"devin","path":"~/devin"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["path"].as_str().unwrap().contains("devin"));
}

#[tokio::test]
async fn project_accepts_home_root_with_tilde() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"home","path":"~"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), home.to_str().unwrap());
}

#[tokio::test]
async fn project_accepts_existing_home_subdir_symlink() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    // Create a real dir outside the home and a symlink inside home.
    let real = tempfile::tempdir().unwrap().keep().join("real-dev");
    std::fs::create_dir_all(&real).unwrap();
    let link = home.join("devin-link");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let body = r#"{"name":"devin","path":"devin-link"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
}

#[tokio::test]
async fn project_accepts_home_root_with_dot() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"home","path":"."}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), home.to_str().unwrap());
}

#[tokio::test]
async fn project_accepts_home_root_with_empty_path() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"home","path":""}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), home.to_str().unwrap());
}

#[tokio::test]
async fn project_rejects_traversal() {
    let (state, _db) = app_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"devin","path":"devin/../etc"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("invalid"), "body: {body}");
}

#[tokio::test]
async fn project_rejects_windows_style_traversal() {
    let (state, _db) = app_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"devin","path":"devin\\..\\etc"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("invalid"), "body: {body}");
}

#[tokio::test]
async fn project_rejects_duplicate_path() {
    let (state, _db) = app_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"first","path":"dup"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED, "first project");

    let body = r#"{"name":"second","path":"dup"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("path"), "body: {body}");
}

#[tokio::test]
async fn project_rejects_duplicate_name() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let first_dir = home.join("first_dir");
    let second_dir = home.join("second_dir");

    let body = format!(r#"{{"name":"dup","path":"{}"}}"#, first_dir.display());
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED, "first project");

    let body = format!(r#"{{"name":"dup","path":"{}"}}"#, second_dir.display());
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("name"), "body: {body}");
}

#[tokio::test]
async fn project_rejects_duplicate_path_with_tilde() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"tilde","path":"~/dup2"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED, "first project");

    let body = format!(
        r#"{{"name":"abs","path":"{}"}}"#,
        home.join("dup2").display()
    );
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("path"), "body: {body}");
}

#[tokio::test]
async fn project_delete_cascades_threads() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/projects/{pid}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/project"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn project_reorder_updates_list() {
    let (state, _db) = app_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let id1 = create_project(&app, &cookie).await;
    let id2 = create_project(&app, &cookie).await;
    let id3 = create_project(&app, &cookie).await;

    let body = format!(r#"{{"project_ids":[{id3},{id1},{id2}]}}"#);
    let resp = app
        .clone()
        .oneshot(authed("PATCH", "/api/projects/reorder", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: serde_json::Value = serde_json::from_str(&body).unwrap();
    let ids: Vec<i64> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, vec![id3, id1, id2]);

    // Missing a project is rejected.
    let body = format!(r#"{{"project_ids":[{id3},{id1}]}}"#);
    let resp = app
        .clone()
        .oneshot(authed("PATCH", "/api/projects/reorder", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Duplicate project ids are rejected.
    let body = format!(r#"{{"project_ids":[{id3},{id3},{id1}]}}"#);
    let resp = app
        .clone()
        .oneshot(authed("PATCH", "/api/projects/reorder", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn project_reorder_keeps_pinned_projects_first() {
    let (state, _db) = app_state().await;
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let id1 = create_project(&app, &cookie).await;
    let id2 = create_project(&app, &cookie).await;

    // Pin the second project.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{id2}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Reorder with the unpinned project first; pinned should still float to top.
    let body = format!(r#"{{"project_ids":[{id1},{id2}]}}"#);
    let resp = app
        .clone()
        .oneshot(authed("PATCH", "/api/projects/reorder", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: serde_json::Value = serde_json::from_str(&body).unwrap();
    let ids: Vec<i64> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, vec![id2, id1]);
}

#[tokio::test]
async fn project_rename_updates_name() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/projects/{pid}"),
            &cookie,
            r#"{"name":"Renamed"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["name"].as_str().unwrap(), "Renamed");
    assert_eq!(v["id"].as_i64().unwrap(), pid);

    // The list reflects the new name.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(list.as_array().unwrap().len(), 1);
    assert!(list[0]["name"].as_str().unwrap().contains("Renamed"));
}

#[tokio::test]
async fn project_rename_rejects_empty_name() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/projects/{pid}"),
            &cookie,
            r#"{"name":"   "}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn project_rename_is_isolated_between_users() {
    let (app, _db) = make_app().await;
    let owner_cookie = login(&app).await;

    create_user(&app, &owner_cookie, "alice", "alicepass123").await;
    let owner_pid = create_project(&app, &owner_cookie).await;

    let alice_cookie = login_as(&app, "alice", "alicepass123").await;
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/projects/{owner_pid}"),
            &alice_cookie,
            r#"{"name":"Stolen"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn project_pin_success_and_sorts_first() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let _pid_a = create_project(&app, &cookie).await;
    let pid_b = create_project(&app, &cookie).await;

    // Pin the second project.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid_b}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["pinned"].as_bool().unwrap());
    assert_eq!(v["id"].as_i64().unwrap(), pid_b);

    // Listing projects puts the pinned one first.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    assert_eq!(list.len(), 2);
    assert!(list[0]["pinned"].as_bool().unwrap());
    assert_eq!(list[0]["id"].as_i64().unwrap(), pid_b);
}

#[tokio::test]
async fn project_unpin_success() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/pin"),
            &cookie,
            r#"{"pinned":false}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list: Vec<serde_json::Value> = serde_json::from_str(&body).unwrap();
    assert!(!list[0]["pinned"].as_bool().unwrap());
}

#[tokio::test]
async fn project_no_op_pin_does_not_update_updated_at() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let first = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    let body = body_str(first.into_body()).await;
    let first_v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let first_updated = first_v["updated_at"].as_str().unwrap();

    let second = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/pin"),
            &cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
    let body = body_str(second.into_body()).await;
    let second_v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let second_updated = second_v["updated_at"].as_str().unwrap();

    assert_eq!(first_updated, second_updated);
}

#[tokio::test]
async fn project_pin_is_isolated_between_users() {
    let (app, _db) = make_app().await;
    let owner_cookie = login(&app).await;
    create_user(&app, &owner_cookie, "alice", "alicepass123").await;
    let owner_pid = create_project(&app, &owner_cookie).await;

    let alice_cookie = login_as(&app, "alice", "alicepass123").await;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{owner_pid}/pin"),
            &alice_cookie,
            r#"{"pinned":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn project_accepts_tilde_with_trailing_slash() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"name":"home","path":"~/"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, body))
        .await
        .unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "body: {}",
        body_str(resp.into_body()).await
    );
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), home.to_str().unwrap());
}

#[tokio::test]
async fn file_manager_lists_absolute_path_with_spaces() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let outside = tempfile::tempdir().unwrap().keep();
    let target = outside.join("my drive").join("my app");
    std::fs::create_dir_all(&target).unwrap();

    let encoded = target.to_string_lossy().replace(' ', "%20");
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/files?path={encoded}"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn file_manager_uploads_to_absolute_dir_with_spaces() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let outside = tempfile::tempdir().unwrap().keep();
    let dest_dir = outside.join("my drive").join("my app");
    std::fs::create_dir_all(&dest_dir).unwrap();

    let boundary = "----fmboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n{}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\nContent-Type: text/plain\r\n\r\nhi there\r\n--{boundary}--\r\n",
        dest_dir.display()
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

    let file = dest_dir.join("hello.txt");
    assert!(file.exists());
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
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;

    // Create two threads. Both need messages so they aren't treated as
    // empty drafts and deleted when the next thread is created.
    let tid_a = make_thread(&app, &cookie, pid, "Thread A").await;
    seed_messages(&db, &tid_a, 1, "msg-a").await;
    let tid_b = make_thread(&app, &cookie, pid, "Thread B").await;
    seed_messages(&db, &tid_b, 1, "msg-b").await;

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
    assert!(
        body.contains(r#""provider_id":"devin-cli""#),
        "body: {body}"
    );

    // Confirm it actually persisted.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(r#""provider_id":"devin-cli""#),
        "body: {body}"
    );
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

fn init_git_repo(path: &std::path::Path) {
    std::fs::create_dir_all(path).unwrap();
    let mut cmd = std::process::Command::new("git");
    cmd.arg("init").current_dir(path);
    assert!(cmd.output().unwrap().status.success());
    let mut cfg = std::process::Command::new("git");
    cfg.args(["config", "user.email", "test@example.com"])
        .current_dir(path);
    assert!(cfg.output().unwrap().status.success());
    let mut cfg = std::process::Command::new("git");
    cfg.args(["config", "user.name", "Test"]).current_dir(path);
    assert!(cfg.output().unwrap().status.success());
    std::fs::write(path.join("file.txt"), "hello").unwrap();
    let mut add = std::process::Command::new("git");
    add.args(["add", "file.txt"]).current_dir(path);
    assert!(add.output().unwrap().status.success());
    let mut commit = std::process::Command::new("git");
    commit
        .args(["commit", "-m", "initial"])
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test")
        .current_dir(path);
    assert!(commit.output().unwrap().status.success());
}

async fn create_git_project(app: &Router, cookie: &str, path: &std::path::Path) -> i64 {
    let body = format!(
        r#"{{"name":"git-{}","path":"{}"}}"#,
        Uuid::new_v4(),
        path.display()
    );
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

#[tokio::test]
async fn git_status_for_non_git_project() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let status = resp.status();
    let body = body_str(resp.into_body()).await;
    if status != StatusCode::OK {
        eprintln!("status: {status}, body: {body}");
    }
    assert_eq!(status, StatusCode::OK);
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["is_repo"], false);
}

#[tokio::test]
async fn git_branches_and_checkout() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/branches"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let branches = v["branches"].as_array().unwrap();
    let default = v["default"].as_str().unwrap();
    assert!(!default.is_empty());
    assert!(branches.iter().any(|b| b["name"] == default));

    let body = r#"{"name":"new-feature","switch":true}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/branches"),
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let body = format!(r#"{{"ref_name":"{default}"}}"#);
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/checkout"),
            &cookie,
            &body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn git_pull_branch_rejects_untracked_branch() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);

    let mut branch_cmd = std::process::Command::new("git");
    branch_cmd.args(["branch", "untracked"]).current_dir(&repo);
    assert!(branch_cmd.output().unwrap().status.success());

    let pid = create_git_project(&app, &cookie, &repo).await;

    let body = r#"{"name":"untracked"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/branches/pull"),
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let text = body_str(resp.into_body()).await;
    assert!(text.to_lowercase().contains("no upstream"));
}

#[tokio::test]
async fn git_worktree_create_delete() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let body = r#"{"name":"wt1","base":"HEAD","new_branch":true}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/worktrees"),
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let wt_path = v["path"].as_str().unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/worktrees"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = format!(r#"{{"worktree_path":"{wt_path}"}}"#);
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            &format!("/api/projects/{pid}/git/worktrees"),
            &cookie,
            &body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn git_rejects_path_traversal_worktree() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let body = r#"{"name":"../escape","base":"HEAD","new_branch":true}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/worktrees"),
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_create_with_git_context() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let body = format!(
        r#"{{"project_id":{pid},"title":"git-thread","branch":"main","worktree_path":""}}"#
    );
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/threads", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["branch"], "main");
}

#[tokio::test]
async fn thread_create_defaults_env_mode_to_local() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"default"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["env_mode"], "local");
}

#[tokio::test]
async fn thread_create_accepts_worktree_env_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"wt-thread","env_mode":"worktree"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["env_mode"], "worktree");
}

#[tokio::test]
async fn thread_rejects_invalid_env_mode() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"bad","env_mode":"cloud"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_send_worktree_mode_creates_auto_worktree() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"auto-wt","env_mode":"worktree"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    let boundary = "----wtboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHello\r\n--{boundary}--\r\n"
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

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let thread = &v["thread"];
    let branch = thread["branch"].as_str().unwrap();
    let worktree_path = thread["worktree_path"].as_str().unwrap();

    assert!(
        branch.starts_with("devinorium/"),
        "unexpected branch: {branch}"
    );
    assert!(!worktree_path.is_empty());
    assert!(std::path::Path::new(worktree_path).exists());
}

#[tokio::test]
async fn thread_send_worktree_mode_reuses_existing_worktree() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"reuse-wt","env_mode":"worktree"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    let boundary = "----wtboundary2";
    let send = || async {
        let body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nHi\r\n--{boundary}--\r\n"
        );
        app.clone()
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
            .unwrap()
    };

    let resp = send().await;
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let first = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let first_wt = first["thread"]["worktree_path"].as_str().unwrap();

    let resp = send().await;
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let second = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(
        second["thread"]["worktree_path"].as_str().unwrap(),
        first_wt
    );
}

#[tokio::test]
async fn thread_local_mode_detects_agent_created_worktree() {
    // The agent runs shell commands from the project's working directory and
    // may run `git worktree add` on its own. The backend should notice the new
    // worktree after the run, associate the thread with it, and flip it to
    // worktree mode so the indicator and future prompts follow it.
    let (app, _db) = make_app_with_provider(Arc::new(WorktreeCreatingProvider)).await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"agent-wt","env_mode":"local"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    let boundary = "----agentwt";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nmake a worktree\r\n--{boundary}--\r\n"
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

    wait_for_run(&app, &cookie, tid, |b| {
        b.contains(r#""status":"completed""#)
    })
    .await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let thread = &v["thread"];
    let worktree_path = thread["worktree_path"].as_str().unwrap();
    assert!(!worktree_path.is_empty());
    assert!(std::path::Path::new(worktree_path).exists());
    assert_eq!(thread["env_mode"], "worktree");
    assert_eq!(thread["branch"], "agent-wt");
}

#[tokio::test]
async fn thread_local_mode_no_new_worktree_stays_local() {
    // When the agent does not create a worktree, the thread should remain in
    // local mode with no worktree path.
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"no-wt","env_mode":"local"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    send_prompt(&app, &cookie, tid, "hello").await;
    wait_for_run(&app, &cookie, tid, |b| {
        b.contains(r#""status":"completed""#)
    })
    .await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["thread"]["env_mode"], "local");
    assert!(v["thread"]["worktree_path"].is_null());
}

#[tokio::test]
async fn thread_existing_worktree_not_overwritten_by_detection() {
    // A thread that already has an explicit worktree_path must not be
    // reassigned to a different worktree the agent creates during the run.
    let (app, _db) = make_app_with_provider(Arc::new(WorktreeCreatingProvider)).await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    // Create a first worktree and assign the thread to it explicitly.
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            &format!("/api/projects/{pid}/git/worktrees"),
            &cookie,
            r#"{"name":"explicit-wt","base":"HEAD","new_branch":true}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let wt_body = body_str(resp.into_body()).await;
    let wt_v = serde_json::from_str::<serde_json::Value>(&wt_body).unwrap();
    let explicit_wt = wt_v["path"].as_str().unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"has-wt","env_mode":"worktree"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    // Run once so ensure_thread_worktree assigns the thread its own worktree.
    send_prompt(&app, &cookie, tid, "first prompt").await;
    wait_for_run(&app, &cookie, tid, |b| {
        b.contains(r#""status":"completed""#)
    })
    .await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let first_wt = v["thread"]["worktree_path"].as_str().unwrap();
    assert!(!first_wt.is_empty());

    // Now the agent creates a second worktree during the next run.
    send_prompt(&app, &cookie, tid, "make another worktree").await;
    wait_for_run(&app, &cookie, tid, |b| {
        b.contains(r#""status":"completed""#)
    })
    .await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    // The thread must still point at the original worktree, not the
    // agent-created "agent-wt".
    assert_eq!(v["thread"]["worktree_path"].as_str().unwrap(), first_wt);
    assert_ne!(v["thread"]["worktree_path"].as_str().unwrap(), explicit_wt);
}

/// A stub provider that simulates the agent running `git worktree add` in the
/// project's working directory during a run.
struct WorktreeCreatingProvider;

#[async_trait]
impl Provider for WorktreeCreatingProvider {
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
        let wt_path = req.options.working_dir.join("agent-wt");
        let output = std::process::Command::new("git")
            .args(["worktree", "add", "-b", "agent-wt"])
            .arg(&wt_path)
            .arg("HEAD")
            .current_dir(&req.options.working_dir)
            .output()
            .map_err(|e| anyhow::anyhow!("git worktree add failed: {e}"))?;
        if !output.status.success() {
            tracing::error!(
                status = ?output.status,
                stderr = %String::from_utf8_lossy(&output.stderr),
                "WorktreeCreatingProvider git worktree add failed",
            );
        }
        let session_id = "stub-session-wt".to_string();
        if let Some(cb) = &req.options.session_callback {
            cb(session_id.clone()).await;
        }
        Ok(StartResponse {
            session_id,
            reply: "created a worktree".into(),
            thinking: String::new(),
            parts: vec![MessagePart::text("created a worktree")],
            title: "agent-wt".into(),
            usage: None,
        })
    }
    async fn send(&self, _req: SendRequest) -> anyhow::Result<SendResponse> {
        Ok(SendResponse {
            reply: "ok".into(),
            thinking: String::new(),
            parts: vec![MessagePart::text("ok")],
            usage: None,
        })
    }
    async fn export(&self, _sid: &str, _wd: &std::path::Path) -> anyhow::Result<serde_json::Value> {
        Ok(serde_json::json!({}))
    }
    async fn health_check(&self) -> anyhow::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn thread_send_worktree_mode_is_idempotent_under_concurrency() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"concurrent-wt","env_mode":"worktree"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let tid = v["id"].as_str().unwrap();

    let boundary = "----wtboundary3";
    let send = |prompt: &str| {
        let app = app.clone();
        let cookie = cookie.clone();
        let tid = tid.to_string();
        let boundary = boundary.to_string();
        let body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{prompt}\r\n--{boundary}--\r\n"
        );
        async move {
            app.oneshot(
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
            .unwrap()
        }
    };

    let (a, b) = tokio::join!(send("A"), send("B"));
    assert!(
        a.status() == StatusCode::OK || b.status() == StatusCode::OK,
        "expected at least one send to succeed: {:?} {:?}",
        a.status(),
        b.status()
    );

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let branch = v["thread"]["branch"].as_str().unwrap();
    let worktree_path = v["thread"]["worktree_path"].as_str().unwrap();

    assert!(branch.starts_with("devinorium/"));
    assert!(!worktree_path.is_empty());
    assert!(std::path::Path::new(worktree_path).exists());

    // The repository should have exactly one worktree for the generated branch.
    let output = std::process::Command::new("git")
        .args(["worktree", "list"])
        .current_dir(&repo)
        .output()
        .unwrap();
    let listing = std::str::from_utf8(&output.stdout).unwrap();
    assert_eq!(
        listing.lines().filter(|l| l.contains(branch)).count(),
        1,
        "expected exactly one worktree for the thread branch"
    );
}

fn write_fake_glab(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
set -e
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
  if [ "$3" = "token" ]; then
    mkdir -p "$XDG_CONFIG_HOME"
    printf '%s' "$4" > "$XDG_CONFIG_HOME/token"
  fi
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  if [ -f "$XDG_CONFIG_HOME/token" ] && [ -s "$XDG_CONFIG_HOME/token" ]; then
    echo "$host"
    echo "  Logged in to $host as testuser"
    exit 0
  else
    echo "$host"
    echo "  ! No token found"
    exit 1
  fi
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then
  rm -f "$XDG_CONFIG_HOME/token"
  echo "Successfully logged out"
  exit 0
fi
if [ "$1" = "api" ]; then
  path="$2"
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  printf '{"host":"%s","path":"%s"}\n' "$host" "$path"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

fn write_fake_glab_with_pipelines(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
set -e
if [ "$1" = "config" ] && [ "$2" = "set" ]; then
  if [ "$3" = "token" ]; then
    mkdir -p "$XDG_CONFIG_HOME"
    printf '%s' "$4" > "$XDG_CONFIG_HOME/token"
  fi
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  if [ -f "$XDG_CONFIG_HOME/token" ] && [ -s "$XDG_CONFIG_HOME/token" ]; then
    echo "$host"
    echo "  Logged in to $host as testuser"
    exit 0
  else
    echo "$host"
    echo "  ! No token found"
    exit 1
  fi
fi
if [ "$1" = "auth" ] && [ "$2" = "logout" ]; then
  rm -f "$XDG_CONFIG_HOME/token"
  echo "Successfully logged out"
  exit 0
fi
if [ "$1" = "api" ]; then
  path="$2"
  case "$path" in
    *"/jobs"*)
      printf '[{"id":101,"name":"cargo test","status":"running","stage":"test","web_url":"https://gitlab.example.com/-/jobs/101","started_at":"2026-01-01T00:00:00Z","finished_at":"","duration":0},{"id":102,"name":"flutter test","status":"success","stage":"test","web_url":"https://gitlab.example.com/-/jobs/102","started_at":"2026-01-01T00:00:00Z","finished_at":"2026-01-01T00:01:00Z","duration":60.5}]\n'
      exit 0
      ;;
    *"/pipelines"*)
      if echo "$path" | grep -q "empty"; then
        printf '[]\n'
      else
        printf '[{"id":42,"status":"success","name":"test-and-build","web_url":"https://gitlab.example.com/group/project/-/pipelines/42","ref":"feature"}]\n'
      fi
      exit 0
      ;;
  esac
  host="gitlab.com"
  if [ "$3" = "--hostname" ]; then
    host="$4"
  fi
  printf '{"host":"%s","path":"%s"}\n' "$host" "$path"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

fn write_glab_token_file(config_root: &std::path::Path, user_id: i64) {
    let token_file = config_root
        .join("glab")
        .join(user_id.to_string())
        .join(".config")
        .join("token");
    std::fs::create_dir_all(token_file.parent().unwrap()).unwrap();
    std::fs::write(&token_file, "glpat-test").unwrap();
}

#[tokio::test]
async fn git_connections_list_login_logout() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home.clone(), Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/git-connections", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let list = serde_json::from_str::<Vec<serde_json::Value>>(&body).unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0]["id"], "gitlab");
    assert!(!list[0]["authed"].as_bool().unwrap());
    assert_eq!(list[1]["id"], "github");
    assert!(list[1]["coming_soon"].as_bool().unwrap());

    // Simulate glab already being authenticated on the host.
    write_glab_token_file(&home, 1);

    let body = r#"{"hostname":"gitlab.example.com"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/git-connections/gitlab", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["account"], "testuser");
    assert_eq!(v["host"], "gitlab.example.com");

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/git-connections", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let list = serde_json::from_str::<Vec<serde_json::Value>>(&body).unwrap();
    let gitlab = list.iter().find(|c| c["id"] == "gitlab").unwrap();
    assert!(gitlab["authed"].as_bool().unwrap());
    assert_eq!(gitlab["account"], "testuser");

    let body = r#"{"hostname":"gitlab.example.com"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "DELETE",
            "/api/git-connections/gitlab",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/git-connections", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let list = serde_json::from_str::<Vec<serde_json::Value>>(&body).unwrap();
    let gitlab = list.iter().find(|c| c["id"] == "gitlab").unwrap();
    assert!(!gitlab["authed"].as_bool().unwrap());
}

#[tokio::test]
async fn git_connections_login_fails_when_glab_not_authed() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/git-connections/gitlab", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_login_defaults_to_gitlab_com() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab(&home);
    write_glab_token_file(&home, 1);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/git-connections/gitlab", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["host"], "gitlab.com");
    assert!(v["authed"].as_bool().unwrap());
}

#[tokio::test]
async fn git_connections_gitlab_proxy_forwards_api_requests() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/proxy?path=projects/group%252Fproject/merge_requests/1&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["host"], "gitlab.example.com");
    assert_eq!(v["path"], "projects/group%2Fproject/merge_requests/1");
}

#[tokio::test]
async fn git_connections_gitlab_pipelines_returns_pipelines_list() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines?project=group%2Fproject&iid=1&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v.is_array());
    assert_eq!(v.as_array().unwrap().len(), 1);
    assert_eq!(v[0]["status"], "success");
    assert_eq!(v[0]["name"], "test-and-build");
    assert_eq!(
        v[0]["web_url"],
        "https://gitlab.example.com/group/project/-/pipelines/42"
    );
    assert_eq!(v[0]["ref_name"], "feature");
}

#[tokio::test]
async fn git_connections_gitlab_pipelines_returns_empty_list_when_none() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines?project=empty%2Fproject&iid=1&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v.is_array());
    assert!(v.as_array().unwrap().is_empty());
}

#[tokio::test]
async fn git_connections_gitlab_pipelines_rejects_invalid_iid() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines?project=group%2Fproject&iid=0",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_gitlab_pipeline_jobs_returns_jobs_list() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs?project=group%2Fproject&pipeline_id=42&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v.is_array());
    assert_eq!(v.as_array().unwrap().len(), 2);
    assert_eq!(v[0]["name"], "cargo test");
    assert_eq!(v[0]["status"], "running");
    assert_eq!(v[1]["name"], "flutter test");
    assert_eq!(v[1]["status"], "success");
    assert_eq!(v[1]["duration"], 60.5);
}

#[tokio::test]
async fn git_connections_gitlab_pipeline_jobs_rejects_invalid_pipeline_id() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs?project=group%2Fproject&pipeline_id=0&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_gitlab_pipeline_jobs_rejects_empty_project() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_pipelines(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs?project=&pipeline_id=42&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Fake `glab` that serves a single job and its trace.
fn write_fake_glab_with_job_logs(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
if [ "$1" = "api" ]; then
  path="$2"
  case "$path" in
    *"/trace")
      printf 'line one\nline two\n'
      exit 0
      ;;
    *"/jobs/"*)
      printf '{"id":101,"name":"cargo test","status":"running","stage":"test","web_url":"https://gitlab.example.com/-/jobs/101","started_at":"2026-01-01T00:00:00Z","finished_at":"","duration":0}\n'
      exit 0
      ;;
  esac
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_connections_gitlab_job_log_returns_trace_and_status() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_job_logs(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs/logs?project=group%2Fproject&job_id=101&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["job"]["id"], 101);
    assert_eq!(v["job"]["status"], "running");
    assert_eq!(v["trace"], "line one\nline two\n");
}

#[tokio::test]
async fn git_connections_gitlab_job_log_rejects_invalid_job_id() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_job_logs(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs/logs?project=group%2Fproject&job_id=0&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_gitlab_job_log_rejects_empty_project() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_job_logs(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/git-connections/gitlab/pipelines/jobs/logs?project=&job_id=101&hostname=gitlab.example.com",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

/// Fake `glab` that echoes the `api` invocation back so tests can assert on
/// the method and fields the backend used.
fn write_echoing_glab(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
if [ "$1" = "api" ]; then
  printf '{"args":"%s"}\n' "$*"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_connections_merge_request_action_closes_merge_request() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body =
        r#"{"project":"group/project","iid":7,"action":"close","hostname":"gitlab.example.com"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let args = v["args"].as_str().unwrap();
    assert!(args.contains("projects/group%2Fproject/merge_requests/7"));
    assert!(args.contains("--method PUT"));
    assert!(args.contains("--field state_event=close"));
    assert!(args.contains("--hostname gitlab.example.com"));
}

#[tokio::test]
async fn git_connections_merge_request_action_merges_when_pipeline_succeeds() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":7,"action":"merge_when_pipeline_succeeds"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let args = v["args"].as_str().unwrap();
    assert!(args.contains("projects/group%2Fproject/merge_requests/7/merge"));
    assert!(args.contains("--field merge_when_pipeline_succeeds=true"));
    assert!(args.contains("--hostname gitlab.com"));
}

#[tokio::test]
async fn git_connections_merge_request_action_reopens_merge_request() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":7,"action":"reopen"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["args"]
        .as_str()
        .unwrap()
        .contains("--field state_event=reopen"));
}

/// Fake `glab` that returns a successful cancel response and logs every
/// `api` invocation to `glab.log` in the temp directory.
fn write_cancelling_glab(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let log_file = dir.join("glab.log");
    let script = format!(
        r#"#!/bin/sh
log_file="{}"
if [ "$1" = "api" ]; then
  echo "$*" >> "$log_file"
  case "$2" in
    *"cancel_merge_when_pipeline_succeeds"*)
      printf '{{"status":"success"}}\n'
      exit 0
      ;;
  esac
fi
echo "unknown glab command: $*" >&2
exit 1
"#,
        log_file.display()
    );
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_connections_merge_request_action_cancels_auto_merge() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_cancelling_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home.clone(), Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":7,"action":"cancel_auto_merge","hostname":"gitlab.example.com"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["status"], "success");

    let log = std::fs::read_to_string(home.join("glab.log")).unwrap();
    let first = log.lines().next().unwrap();
    assert!(first
        .contains("projects/group%2Fproject/merge_requests/7/cancel_merge_when_pipeline_succeeds"));
    assert!(first.contains("--method POST"));
    assert!(first.contains("--hostname gitlab.example.com"));
}

#[tokio::test]
async fn git_connections_merge_request_action_rejects_empty_project() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"","iid":7,"action":"merge"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_merge_request_action_reports_missing_glab() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, None));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":7,"action":"merge"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn git_connections_merge_request_action_rejects_cross_origin_post() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/git-connections/gitlab/merge-requests/actions")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://evil.example.com")
                .header("cookie", cookie)
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"project":"group/project","iid":7,"action":"merge"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn git_connections_merge_request_action_rejects_unknown_action() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":7,"action":"delete"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn git_connections_merge_request_action_rejects_invalid_iid() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let body = r#"{"project":"group/project","iid":0,"action":"merge"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            &cookie,
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_connections_merge_request_action_requires_auth() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_echoing_glab(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));

    let app = devinorium::build_app(state);

    let body = r#"{"project":"group/project","iid":7,"action":"merge"}"#;
    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/git-connections/gitlab/merge-requests/actions",
            "",
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

fn git_cli(args: &[&str], cwd: &std::path::Path) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_AUTHOR_NAME", "Test")
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        .output()
        .expect("git command failed");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[tokio::test]
async fn project_list_includes_git_branch() {
    let (state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let app = devinorium::build_app(state);
    let cookie = login(&app).await;

    let repo_dir = home.join("repo");
    std::fs::create_dir_all(&repo_dir).unwrap();
    git_cli(&["init"], &repo_dir);
    git_cli(&["checkout", "-b", "main"], &repo_dir);

    let body = format!(r#"{{"name":"repo","path":"{}"}}"#, repo_dir.display());
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/projects", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["is_repo"].as_bool().unwrap());
    assert_eq!(v["branch"].as_str().unwrap(), "main");

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let projects = v.as_array().unwrap();
    let project = projects
        .iter()
        .find(|p| p["name"].as_str() == Some("repo"))
        .unwrap();
    assert!(project["is_repo"].as_bool().unwrap());
    assert_eq!(project["branch"].as_str().unwrap(), "main");
}

#[tokio::test]
async fn project_list_paginates() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let mut ids = Vec::new();
    for _ in 0..3 {
        ids.push(create_project(&app, &cookie).await);
    }

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects?limit=2&offset=0", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 2);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/projects?limit=2&offset=2", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn thread_list_paginates() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let mut ids = Vec::new();
    for i in 0..3 {
        let tid = make_thread(&app, &cookie, pid, &format!("T{i}")).await;
        seed_messages(&db, &tid, 1, "msg ").await;
        ids.push(tid);
    }

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads?limit=2&offset=0", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 2);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads?limit=2&offset=2", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn project_threads_paginate() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    for i in 0..3 {
        let tid = make_thread(&app, &cookie, pid, &format!("T{i}")).await;
        seed_messages(&db, &tid, 1, "msg ").await;
    }

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/threads?limit=2&offset=0"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 2);

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/threads?limit=2&offset=2"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn thread_list_runs_returns_empty_when_idle() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads/runs", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let arr = v["running_ids"].as_array().unwrap();
    assert!(arr.is_empty());
}

#[tokio::test]
async fn thread_get_one_returns_total_messages() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["total_messages"], 0);
    assert!(v["messages"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn thread_get_one_includes_messages() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    seed_messages(&db, &tid, 5, "msg ").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}?include_messages=1"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["total_messages"], 5);
    let messages = v["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 5);
    assert_eq!(messages[0]["role"], "user");
}

#[tokio::test]
async fn thread_messages_pagination() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "T").await;

    // Seed 120 messages directly to bypass provider streaming.
    seed_messages(&db, &tid, 120, "msg ").await;

    // Default page is the most recent 50.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let latest = v["messages"].as_array().unwrap();
    assert_eq!(latest.len(), 50);
    assert!(v["total"].as_i64().unwrap() >= 120);
    let latest_first_id = latest[0]["id"].as_i64().unwrap();
    let latest_last_id = latest[latest.len() - 1]["id"].as_i64().unwrap();

    // Page before the first id gets the next older 50.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages?before_id={latest_first_id}&limit=50"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let older = v["messages"].as_array().unwrap();
    assert_eq!(older.len(), 50);
    assert!(older[older.len() - 1]["id"].as_i64().unwrap() < latest_first_id);
    let older_last_id = older[older.len() - 1]["id"].as_i64().unwrap();

    // Page after the older page returns the previously fetched latest 50.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages?after_id={older_last_id}&limit=50"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let newer = v["messages"].as_array().unwrap();
    assert_eq!(newer.len(), 50);
    assert_eq!(newer[0]["id"].as_i64().unwrap(), latest_first_id);
    assert_eq!(
        newer[newer.len() - 1]["id"].as_i64().unwrap(),
        latest_last_id
    );
}

#[tokio::test]
async fn thread_messages_pagination_empty_thread() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Empty").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["messages"].as_array().unwrap().is_empty());
    assert_eq!(v["total"], 0);
}

#[tokio::test]
async fn thread_messages_rejects_before_and_after_together() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Bad").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages?before_id=1&after_id=2"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn huge_thread_messages_pagination_is_fast() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Huge").await;

    // Seed 5,000 messages directly; this should complete quickly.
    seed_messages(&db, &tid, 5000, "message ").await;

    let start = std::time::Instant::now();
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages?limit=50"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    let elapsed = start.elapsed();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let msgs = v["messages"].as_array().unwrap();
    assert_eq!(msgs.len(), 50);
    assert!(
        elapsed.as_millis() < 10000,
        "pagination took {} ms",
        elapsed.as_millis()
    );
}

#[tokio::test]
async fn create_thread_deletes_empty_threads() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    // Create one empty thread.
    let t1 = make_thread(&app, &cookie, pid, "empty1").await;

    // Verify it exists.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let arr = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let arr = arr.as_array().unwrap();
    assert_eq!(arr.len(), 1);

    // Create a new thread — should delete the empty one.
    let _t2 = make_thread(&app, &cookie, pid, "new thread").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let arr = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let arr = arr.as_array().unwrap();
    assert_eq!(arr.len(), 1, "empty thread should have been deleted");
    assert_eq!(arr[0]["title"].as_str().unwrap(), "new thread");

    // The old empty thread ID should no longer be accessible.
    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{t1}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn create_thread_preserves_threads_with_messages() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    // Create a thread and add a message to it.
    let t1 = make_thread(&app, &cookie, pid, "has messages").await;
    seed_messages(&db, &t1, 1, "msg").await;

    // Create an empty thread too.
    let _t2 = make_thread(&app, &cookie, pid, "empty").await;

    // Create a new thread — should only delete the empty one.
    let _t3 = make_thread(&app, &cookie, pid, "new thread").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let threads = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let arr = threads.as_array().unwrap();
    assert_eq!(arr.len(), 2, "thread with messages should be preserved");
    let titles: Vec<&str> = arr.iter().map(|t| t["title"].as_str().unwrap()).collect();
    assert!(titles.contains(&"has messages"));
    assert!(titles.contains(&"new thread"));
    assert!(!titles.contains(&"empty"));
}

#[tokio::test]
async fn clone_root_owner_can_set_and_create_missing_directory() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    let clone_dir = root.join("clones");
    assert!(!clone_dir.exists());

    let body = serde_json::json!({"path": clone_dir.to_string_lossy()}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/settings/clone-root", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), clone_dir.to_string_lossy());
    assert!(tokio::fs::try_exists(&clone_dir).await.unwrap());
    assert!(tokio::fs::metadata(&clone_dir).await.unwrap().is_dir());
}

#[tokio::test]
async fn clone_root_owner_can_clear() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    let body = serde_json::json!({"path": root.to_string_lossy()}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/settings/clone-root", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    for clear_body in [r#"{"path":""}"#, r#"{"path":null}"#] {
        let resp = app
            .clone()
            .oneshot(authed(
                "PUT",
                "/api/settings/clone-root",
                &cookie,
                clear_body,
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "clear body: {clear_body}");
        let body = body_str(resp.into_body()).await;
        let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
        assert!(v["path"].is_null());

        let resp = app
            .clone()
            .oneshot(authed("GET", "/api/settings/clone-root", &cookie, ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = body_str(resp.into_body()).await;
        let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
        assert!(v["path"].is_null());
    }
}

#[tokio::test]
async fn clone_root_non_owner_can_get_but_not_set() {
    let (app, _db) = make_app().await;
    let owner_cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    let body = serde_json::json!({"path": root.to_string_lossy()}).to_string();
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/settings/clone-root",
            &owner_cookie,
            &body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let uid = create_user(&app, &owner_cookie, "member", "supersecret123").await;
    let member_cookie = login_as(&app, "member", "supersecret123").await;

    // Non-owner GET returns the owner's configured clone root.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/settings/clone-root",
            &member_cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), root.to_string_lossy());

    // Non-owner PUT is forbidden.
    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/settings/clone-root",
            &member_cookie,
            r#"{"path":"/another/path"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // The clone root should be unchanged (the owner value, not the attempted path).
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/settings/clone-root",
            &member_cookie,
            "",
        ))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), root.to_string_lossy());

    // Sanity: the new user's own clone_root is still null.
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT clone_root FROM users WHERE id = ?")
            .bind(uid)
            .fetch_optional(_db.pool())
            .await
            .unwrap();
    assert!(row.unwrap().0.is_none());
}

#[tokio::test]
async fn clone_root_rejects_relative_and_traversal_paths() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let cases = [
        (r#"{"path":"relative/path"}"#, "relative"),
        (r#"{"path":"../escape"}"#, "relative with parent"),
        (r#"{"path":"/tmp/../etc"}"#, "traversal"),
        (r#"{"path":"~/../../etc"}"#, "tilde traversal"),
    ];

    for (body, label) in cases {
        let resp = app
            .clone()
            .oneshot(authed("PUT", "/api/settings/clone-root", &cookie, body))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "{label} should be rejected"
        );
    }
}

#[tokio::test]
async fn clone_root_expands_tilde_path() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PUT",
            "/api/settings/clone-root",
            &cookie,
            r#"{"path":"~/clones"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let resolved = v["path"].as_str().unwrap();
    assert!(
        resolved.contains("clones"),
        "resolved path should contain 'clones': {resolved}"
    );
    assert!(tokio::fs::try_exists(resolved).await.unwrap());

    // GET returns the expanded absolute path.
    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/settings/clone-root", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["path"].as_str().unwrap(), resolved);
}

#[tokio::test]
async fn clone_root_rejects_existing_file() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    let file = root.join("not-a-dir");
    tokio::fs::write(&file, b"nope").await.unwrap();

    let body = serde_json::json!({"path": file.to_string_lossy()}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/settings/clone-root", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

fn write_fake_glab_with_branch_merge_requests(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
set -e
if [ "$1" = "api" ]; then
  path="$2"
  case "$path" in
    *"merge_requests?source_branch=feature%2Fbranch"*"state=opened"*)
      printf '[{"iid":12,"title":"Add feature","state":"opened","source_branch":"feature/branch","target_branch":"main","web_url":"https://gitlab.example.com/group/project/-/merge_requests/12","draft":false}]\n'
      exit 0
      ;;
    *"merge_requests?source_branch=empty"*"state=opened"*)
      printf '[]\n'
      exit 0
      ;;
  esac
  printf '{"host":"%s","path":"%s"}\n' "$3" "$path"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

async fn make_gitlab_project(app: &Router, cookie: &str, repo: &std::path::Path) -> i64 {
    let mut remote = std::process::Command::new("git");
    remote
        .args([
            "remote",
            "add",
            "origin",
            "git@gitlab.example.com:group/project.git",
        ])
        .current_dir(repo);
    assert!(remote.output().unwrap().status.success());
    create_git_project(app, cookie, repo).await
}

#[tokio::test]
async fn git_merge_request_for_branch_returns_match() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_branch_merge_requests(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));
    let app = devinorium::build_app(state);

    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request?branch=feature%2Fbranch"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["iid"], 12);
    assert_eq!(v["title"], "Add feature");
    assert_eq!(v["source_branch"], "feature/branch");
    assert_eq!(v["target_branch"], "main");
    assert_eq!(
        v["web_url"],
        "https://gitlab.example.com/group/project/-/merge_requests/12"
    );
}

#[tokio::test]
async fn git_merge_request_for_branch_returns_no_content_when_none() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_branch_merge_requests(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));
    let app = devinorium::build_app(state);

    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request?branch=empty"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn git_merge_request_for_branch_rejects_missing_branch() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = create_git_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_merge_request_for_branch_404_when_glab_missing() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    // Force no glab binary so the lookup is deterministic regardless of what
    // is installed on the test machine.
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, None));
    let app = devinorium::build_app(state);

    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request?branch=feature"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

fn write_fake_glab_with_merge_request_by_iid(dir: &std::path::Path) -> std::path::PathBuf {
    let bin_dir = dir.join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    let bin = bin_dir.join("glab");
    let script = r#"#!/bin/sh
set -e
if [ "$1" = "api" ]; then
  path="$2"
  case "$path" in
    *"merge_requests/7"*)
      printf '{"iid":7,"title":"By IID","state":"merged","source_branch":"feature/branch","target_branch":"main","web_url":"https://gitlab.example.com/group/project/-/merge_requests/7","draft":false}\n'
      exit 0
      ;;
  esac
  printf '{"host":"%s","path":"%s"}\n' "$3" "$path"
  exit 0
fi
echo "unknown glab command: $*" >&2
exit 1
"#;
    std::fs::write(&bin, script).unwrap();
    let mut perms = std::fs::metadata(&bin).unwrap().permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&bin, perms).unwrap();
    bin
}

#[tokio::test]
async fn git_merge_request_for_iid_returns_match() {
    let (mut state, _db) = app_state().await;
    let home = state.config.home_dir.clone();
    let glab = write_fake_glab_with_merge_request_by_iid(&home);
    state.git_remote = Arc::new(GitRemoteService::with_glab_bin(home, Some(glab)));
    let app = devinorium::build_app(state);

    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request?iid=7"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert_eq!(v["iid"], 7);
    assert_eq!(v["title"], "By IID");
    assert_eq!(v["state"], "merged");
}

#[tokio::test]
async fn git_merge_request_for_iid_rejects_invalid_iid() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request?iid=0"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn git_merge_request_requires_branch_or_iid() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/projects/{pid}/git/merge-request"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_link_merge_request_validates_and_persists() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "link test").await;

    let url = "https://gitlab.example.com/group/project/-/merge_requests/12";
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            &format!(r#"{{"linked_mr":"{url}"}}"#),
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
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let linked = &v["thread"]["linked_mr"];
    assert_eq!(linked["hostname"], "gitlab.example.com");
    assert_eq!(linked["project_path"], "group/project");
    assert_eq!(linked["iid"], 12);
    assert_eq!(linked["web_url"], url);

    // Unlinking clears the stored link.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"linked_mr":null}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["thread"]["linked_mr"].is_null());
}

#[tokio::test]
async fn thread_link_merge_request_rejects_mismatched_remote() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "mismatch test").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"linked_mr":"https://gitlab.example.com/other/project/-/merge_requests/1"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_link_merge_request_rejects_malformed_url() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "bad url").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"linked_mr":"not-a-url"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_link_merge_request_empty_string_clears() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "clear test").await;

    let url = "https://gitlab.example.com/group/project/-/merge_requests/1";
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            &format!(r#"{{"linked_mr":"{url}"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"linked_mr":""}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["thread"]["linked_mr"].is_null());
}

#[tokio::test]
async fn thread_link_merge_request_is_case_and_percent_agnostic() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "case test").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"linked_mr":"https://GITLAB.EXAMPLE.COM/group%2Fproject/-/merge_requests/5"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let linked = &v["thread"]["linked_mr"];
    assert_eq!(linked["hostname"], "gitlab.example.com");
    assert_eq!(linked["project_path"], "group/project");
    assert_eq!(linked["iid"], 5);
}

#[tokio::test]
async fn thread_send_auto_links_merge_request_for_project_remote() {
    let (app, _db) =
        make_app_with_provider(Arc::new(LinkingStubProvider) as Arc<dyn Provider>).await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "auto link").await;

    send_prompt(&app, &cookie, &tid, "make a merge request").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let linked = &v["thread"]["linked_mr"];
    assert_eq!(linked["hostname"], "gitlab.example.com");
    assert_eq!(linked["project_path"], "group/project");
    assert_eq!(linked["iid"], 42);
    assert_eq!(
        linked["web_url"],
        "https://gitlab.example.com/group/project/-/merge_requests/42"
    );
}

#[tokio::test]
async fn thread_send_stream_emits_linked_mr_thread_update() {
    let (app, _db) =
        make_app_with_provider(Arc::new(LinkingStubProvider) as Arc<dyn Provider>).await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "auto link stream").await;

    let boundary = "----linkstreamboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nmake a merge request\r\n--{boundary}--\r\n"
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

    let bytes = to_bytes(resp.into_body(), 10_000).await.unwrap();
    let text = String::from_utf8_lossy(&bytes);

    let update_block = text
        .split("\n\n")
        .find(|b| b.contains("event: thread_update") && b.contains("linked_mr"))
        .expect("thread_update with linked_mr should be emitted");
    let data = update_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("data line")
        .strip_prefix("data: ")
        .unwrap();
    let v: serde_json::Value = serde_json::from_str(data).unwrap();
    let linked = &v["linked_mr"];
    assert_eq!(linked["hostname"], "gitlab.example.com");
    assert_eq!(linked["project_path"], "group/project");
    assert_eq!(linked["iid"], 42);
    assert_eq!(
        linked["web_url"],
        "https://gitlab.example.com/group/project/-/merge_requests/42"
    );
    assert!(v["updated_at"].as_str().is_some_and(|s| !s.is_empty()));
}

#[tokio::test]
async fn thread_send_does_not_auto_link_mismatched_remote() {
    let (app, _db) =
        make_app_with_provider(Arc::new(LinkingStubProvider) as Arc<dyn Provider>).await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let mut remote = std::process::Command::new("git");
    remote
        .args([
            "remote",
            "add",
            "origin",
            "git@gitlab.example.com:other/project.git",
        ])
        .current_dir(&repo);
    assert!(remote.output().unwrap().status.success());
    let pid = create_git_project(&app, &cookie, &repo).await;
    let tid = make_thread(&app, &cookie, pid, "no auto link").await;

    send_prompt(&app, &cookie, &tid, "make a merge request").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["thread"]["linked_mr"].is_null());
}

#[tokio::test]
async fn create_thread_ignores_unsupported_linked_mr() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    init_git_repo(&repo);
    let pid = make_gitlab_project(&app, &cookie, &repo).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(
                r#"{{"project_id":{pid},"title":"ignored","linked_mr":"https://gitlab.example.com/group/project/-/merge_requests/1"}}"#
            ),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    assert!(v["thread"]["linked_mr"].is_null());
}

/// A stub provider that emits a `<proposed_plan>` block in its reply.
struct PlanStubProvider;

#[async_trait]
impl Provider for PlanStubProvider {
    fn id(&self) -> &str {
        "plan-stub"
    }
    fn name(&self) -> &str {
        "Plan Stub"
    }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        Ok(vec![ModelInfo {
            id: "plan-stub-1".into(),
            label: "Plan Stub One".into(),
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
        let text = r#"<update_plan explanation="Build the thing"><step status="completed">A</step><step status="in_progress">B</step></update_plan>"#;
        let parts = vec![MessagePart::text(text)];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        Ok(StartResponse {
            session_id: "plan-stub-session".into(),
            reply: text.into(),
            thinking: "".into(),
            parts,
            title: "Plan Thread".into(),
            usage: None,
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let text = r#"<update_plan explanation="Build the thing"><step status="completed">A</step><step status="in_progress">B</step></update_plan>"#;
        let parts = vec![MessagePart::text(text)];
        if let Some(cb) = &req.options.part_callback {
            for part in &parts {
                cb(PartEvent::New(part.clone()));
            }
        }
        Ok(SendResponse {
            reply: text.into(),
            thinking: "".into(),
            parts,
            usage: None,
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

async fn make_app_with_provider(provider: Arc<dyn Provider>) -> (Router, db::Db) {
    let (mut state, db) = app_state().await;
    state.provider = provider;
    let router = devinorium::build_app(state);
    (router, db)
}

#[tokio::test]
async fn thread_plan_endpoint_returns_latest_plan() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Plan test").await;
    db.upsert_latest_plan(
        &tid,
        None,
        &Plan::new(
            Some("Build the thing".into()),
            vec![
                PlanStep::new("Step one", devinorium::plan::PlanStepStatus::Completed),
                PlanStep::new("Step two", devinorium::plan::PlanStepStatus::Pending),
            ],
        ),
    )
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/plan"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""explanation":"Build the thing""#));
    assert!(body.contains(r#""step":"Step one""#));
    assert!(body.contains(r#""status":"completed""#));
    assert!(body.contains(r#""status":"pending""#));
}

#[tokio::test]
async fn thread_get_one_includes_plan() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Plan detail").await;
    db.upsert_latest_plan(
        &tid,
        None,
        &Plan::new(
            None,
            vec![PlanStep::new(
                "Only step",
                devinorium::plan::PlanStepStatus::InProgress,
            )],
        ),
    )
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""step":"Only step""#));
    assert!(body.contains(r#""status":"in_progress""#));
}

#[tokio::test]
async fn thread_send_stream_emits_plan_update_and_persists_plan() {
    let (app, db) = make_app_with_provider(Arc::new(PlanStubProvider)).await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Plan stream").await;

    let boundary = "test-boundary";
    let payload = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nhello\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\ncode\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nplan-stub-1\r\n--{boundary}--\r\n"
    );
    let req = Request::builder()
        .method("POST")
        .uri(format!("/api/threads/{tid}/send/stream"))
        .header(header::HOST, "localhost")
        .header(header::ORIGIN, "http://localhost")
        .header("cookie", &cookie)
        .header(
            "content-type",
            format!("multipart/form-data; boundary={boundary}"),
        )
        .body(Body::from(payload))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    let status = resp.status();
    let body = body_str(resp.into_body()).await;
    assert_eq!(status, StatusCode::OK, "body: {body}");
    assert!(body.contains(r#"event: plan_update"#), "body: {body}");
    assert!(
        body.contains(r#""explanation":"Build the thing""#),
        "body: {body}"
    );
    assert!(body.contains(r#""step":"A""#), "body: {body}");
    assert!(body.contains(r#""step":"B""#), "body: {body}");

    // Allow the spawned persistence task to finish.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/plan"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let persisted = body_str(resp.into_body()).await;
    assert!(
        persisted.contains(r#""status":"completed""#),
        "persisted: {persisted}"
    );
    assert!(
        persisted.contains(r#""status":"in_progress""#),
        "persisted: {persisted}"
    );

    // The SSE stream and persisted message should not contain raw plan XML.
    assert!(
        !body.contains("<update_plan>"),
        "stream contained raw XML: {body}"
    );
    assert!(
        !body.contains("<proposed_plan>"),
        "stream contained raw XML: {body}"
    );

    let msgs = db.list_messages(&tid).await.unwrap();
    let assistant = msgs.iter().find(|m| m.role == "assistant").unwrap();
    assert_eq!(assistant.content, "");
    assert!(
        !assistant
            .parts
            .as_deref()
            .unwrap_or("")
            .contains("<update_plan>"),
        "parts contained raw XML: {:?}",
        assistant.parts
    );
}

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::protocol::Message;

async fn spawn_router(app: Router) -> (u16, tokio::sync::oneshot::Sender<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let shutdown = async move {
        let _ = rx.await;
    };
    let server = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown);
    tokio::spawn(async move { server.await });
    (port, tx)
}

fn session_cookie(resp: &reqwest::Response) -> String {
    let cookie = resp
        .headers()
        .get_all(axum::http::header::SET_COOKIE)
        .iter()
        .find_map(|h| {
            let s = h.to_str().ok()?;
            s.split(';').next().map(str::trim)
        })
        .unwrap();
    cookie.to_string()
}

#[tokio::test]
async fn terminal_create_kill_and_ws_round_trip() {
    let (app, _db) = make_app().await;
    let (port, shutdown) = spawn_router(app).await;
    let base = format!("http://127.0.0.1:{port}");
    let origin = base.clone();
    let client = reqwest::Client::new();

    // Login as owner.
    let login = client
        .post(format!("{base}/api/auth/login"))
        .header(axum::http::header::ORIGIN, &origin)
        .json(&serde_json::json!({
            "username": "owner",
            "password": "supersecret123",
        }))
        .send()
        .await
        .unwrap();
    assert!(login.status().is_success());
    let cookie = session_cookie(&login);

    // Create a project.
    let project: serde_json::Value = client
        .post(format!("{base}/api/projects"))
        .header(axum::http::header::ORIGIN, &origin)
        .header(axum::http::header::COOKIE, &cookie)
        .json(&serde_json::json!({
            "name": "term project",
            "path": "term",
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let pid = project["id"].as_i64().unwrap();

    // Create a thread.
    let thread: serde_json::Value = client
        .post(format!("{base}/api/threads"))
        .header(axum::http::header::ORIGIN, &origin)
        .header(axum::http::header::COOKIE, &cookie)
        .json(&serde_json::json!({"project_id": pid}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let tid = thread["id"].as_str().unwrap().to_string();

    // Spawn a terminal session using "cat" for a round-trip echo test.
    let term: serde_json::Value = client
        .post(format!("{base}/api/terminal/sessions"))
        .header(axum::http::header::ORIGIN, &origin)
        .header(axum::http::header::COOKIE, &cookie)
        .json(&serde_json::json!({"thread_id": tid}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let terminal_id = term["id"].as_str().unwrap().to_string();

    // Connect to the WebSocket endpoint.
    let ws_url = format!("ws://127.0.0.1:{port}/api/terminal/sessions/{terminal_id}/ws");
    let host = format!("127.0.0.1:{port}");
    let ws_key = tokio_tungstenite::tungstenite::handshake::client::generate_key();
    let req = Request::builder()
        .uri(&ws_url)
        .header("Host", &host)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", &ws_key)
        .header("Cookie", &cookie)
        .header("Origin", &origin)
        .body(())
        .unwrap();
    let (mut ws, _resp) = tokio_tungstenite::connect_async(req).await.unwrap();

    // Send a resize and some input; "cat" will echo the input.
    let _ = ws
        .send(Message::Text(
            r#"{"type":"resize","cols":120,"rows":30}"#.to_string(),
        ))
        .await;
    let _ = ws
        .send(Message::Text(
            r#"{"type":"input","data":"ping"}"#.to_string(),
        ))
        .await;

    // Wait for the echoed output; keep reading until we see "ping".
    let mut saw_ping = false;
    let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(tokio::time::Duration::from_millis(100), ws.next()).await {
            Ok(Some(Ok(Message::Binary(bytes)))) => {
                let text = String::from_utf8_lossy(&bytes);
                if text.contains("ping") {
                    saw_ping = true;
                    break;
                }
            }
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(_))) => break,
            Ok(None) => break,
            Err(_) => {}
        }
    }
    assert!(saw_ping, "expected 'ping' echoed by cat");

    // Kill the terminal via the API.
    let kill = client
        .delete(format!("{base}/api/terminal/sessions/{terminal_id}"))
        .header(axum::http::header::ORIGIN, &origin)
        .header(axum::http::header::COOKIE, &cookie)
        .send()
        .await
        .unwrap();
    assert!(kill.status().is_success());

    // The WebSocket should eventually receive the exited event.
    let mut saw_exited = false;
    let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(tokio::time::Duration::from_millis(100), ws.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
                if text.contains("exited") {
                    saw_exited = true;
                    break;
                }
            }
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(_))) => break,
            Ok(None) => break,
            Err(_) => {}
        }
    }
    assert!(saw_exited, "expected exited event after kill");

    let _ = shutdown.send(());
}

// ---- git clone ----

fn run_git_checked(cwd: &std::path::Path, args: &[&str]) {
    let home = std::env::temp_dir();
    let output = std::process::Command::new("git")
        .current_dir(cwd)
        .env("HOME", &home)
        .env("GIT_AUTHOR_NAME", "test")
        .env("GIT_AUTHOR_EMAIL", "test@test")
        .env("GIT_COMMITTER_NAME", "test")
        .env("GIT_COMMITTER_EMAIL", "test@test")
        .args(args)
        .output()
        .unwrap();
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        panic!("git failed: {stderr}");
    }
}

fn make_bare_repo(base: &std::path::Path) -> std::path::PathBuf {
    let source = base.join("source_repo");
    std::fs::create_dir_all(&source).unwrap();
    run_git_checked(&source, &["init"]);
    std::fs::write(source.join("README.md"), "# hello\n").unwrap();
    run_git_checked(&source, &["add", "README.md"]);
    run_git_checked(&source, &["commit", "-m", "init"]);
    let bare = base.join("source_repo.git");
    run_git_checked(
        base,
        &[
            "clone",
            "--bare",
            source.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    bare
}

async fn set_clone_root(app: &axum::Router, cookie: &str, path: &std::path::Path) {
    let body = serde_json::json!({"path": path.to_string_lossy()}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/settings/clone-root", cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn clone_happy_path() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    let fixture = tempfile::tempdir().unwrap().keep();
    let bare = make_bare_repo(&fixture);
    let url = format!("file://{}", bare.to_string_lossy());

    let body = serde_json::json!({"url": url}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let path = v["path"].as_str().unwrap();
    assert!(path.starts_with(root.to_string_lossy().as_ref()));

    let path = std::path::Path::new(path);
    assert!(tokio::fs::try_exists(path).await.unwrap());
    assert!(path.join(".git").exists() || path.join("HEAD").exists());

    // A project row was created for the cloned repository.
    let project = _db
        .get_project_by_path(1, &path.to_string_lossy())
        .await
        .unwrap();
    assert!(project.is_some());
    assert!(project.unwrap().name.contains("repo"));
}

#[tokio::test]
async fn clone_already_exists() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    let fixture = tempfile::tempdir().unwrap().keep();
    let bare = make_bare_repo(&fixture);
    let url = format!("file://{}", bare.to_string_lossy());

    let body = serde_json::json!({"url": url}).to_string();
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, &body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn clone_missing_root() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let body = r#"{"path":null}"#;
    let resp = app
        .clone()
        .oneshot(authed("PUT", "/api/settings/clone-root", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = r#"{"url":"https://gitlab.com/owner/repo.git"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains("clone root"), "{body}");
}

#[tokio::test]
async fn clone_malformed_url() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    for url in ["", "not-a-url", "ftp://host/path/repo.git"] {
        let body = serde_json::json!({"url": url}).to_string();
        let resp = app
            .clone()
            .oneshot(authed("POST", "/api/clones", &cookie, &body))
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "url should be rejected: {url}"
        );
    }
}

#[tokio::test]
async fn clone_no_owner() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    let body = r#"{"url":"https://gitlab.com/repo.git"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn clone_path_traversal() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    for url in [
        "https://gitlab.com/../owner/repo.git",
        "https://gitlab.com/owner/%2e%2e/repo.git",
    ] {
        let body = serde_json::json!({"url": url}).to_string();
        let resp = app
            .clone()
            .oneshot(authed("POST", "/api/clones", &cookie, &body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{url}");
    }
}

#[tokio::test]
async fn clone_non_gitlab_host_fails_cleanly() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let root = tempfile::tempdir().unwrap().keep();
    set_clone_root(&app, &cookie, &root).await;

    let body = r#"{"url":"git://127.0.0.1:1/owner/repo.git"}"#;
    let resp = app
        .clone()
        .oneshot(authed("POST", "/api/clones", &cookie, body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn thread_messages_turn_windowed_pagination() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "paging").await;

    // Seed 20 messages: 10 user turns with one assistant reply each.
    seed_messages(&_db, &tid, 20, "msg").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages?turn_limit=3"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    let messages = json["messages"].as_array().unwrap();
    let has_more = json["has_more"].as_bool().unwrap();
    let before_cursor = json["before_cursor"].as_str();

    // 3 turns = 6 messages (user + assistant each), ordered by id ascending.
    assert_eq!(messages.len(), 6, "body: {body}");
    assert!(has_more);
    assert!(before_cursor.is_some());

    // Fetch the next older page using the cursor.
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!(
                "/api/threads/{tid}/messages?turn_limit=3&before_cursor={}",
                before_cursor.unwrap()
            ),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    let older = json["messages"].as_array().unwrap();
    assert_eq!(older.len(), 6, "body: {body}");

    // The new oldest ids should be lower than the previous page's oldest id.
    let first_oldest = messages.first().unwrap()["id"].as_i64().unwrap();
    let second_oldest = older.first().unwrap()["id"].as_i64().unwrap();
    assert!(second_oldest < first_oldest);
}

#[tokio::test]
async fn thread_messages_truncates_and_fetches_full_body() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "big").await;

    let big = "x".repeat(250_000);
    let mut conn = _db.pool().acquire().await.unwrap();
    sqlx::query(
        "INSERT INTO messages (thread_id, role, content, thinking, parts, attachments, model, turn_id, seq)
         VALUES (?, 'user', ?, NULL, '[]', '[]', '', 1, 1)",
    )
    .bind(&tid)
    .bind(&big)
    .execute(&mut *conn)
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    let messages = json["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1);
    assert!(messages[0]["truncated"].as_bool().unwrap());
    assert!(messages[0]["total_chars"].as_i64().unwrap() >= 250_000);
    assert!(messages[0]["content"].as_str().unwrap().len() <= 100_000);

    let mid = messages[0]["id"].as_i64().unwrap();
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages/{mid}/full"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["message"]["content"].as_str().unwrap().len(), 250_000);
    assert!(!json["message"]["truncated"].as_bool().unwrap());

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages/{mid}?offset=100000&limit=100000"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["offset"].as_i64().unwrap(), 100_000);
    assert_eq!(json["total_chars"].as_i64().unwrap(), 250_000);
    assert_eq!(json["message"]["content"].as_str().unwrap().len(), 100_000);
}

#[tokio::test]
async fn thread_messages_truncates_multibyte_content_correctly() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "unicode").await;

    // 120,000 'é' characters = 240,000 bytes, but only 120,000 chars.
    let big = "é".repeat(120_000);
    let mut conn = _db.pool().acquire().await.unwrap();
    sqlx::query(
        "INSERT INTO messages (thread_id, role, content, thinking, parts, attachments, model, turn_id, seq)
         VALUES (?, 'user', ?, NULL, '[]', '[]', '', 1, 1)",
    )
    .bind(&tid)
    .bind(&big)
    .execute(&mut *conn)
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    let messages = json["messages"].as_array().unwrap();
    assert!(messages[0]["truncated"].as_bool().unwrap());
    assert_eq!(messages[0]["total_chars"].as_i64().unwrap(), 120_002);
    assert!(messages[0]["content"].as_str().unwrap().chars().count() <= 100_000);

    let mid = messages[0]["id"].as_i64().unwrap();
    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages/{mid}/full"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(
        json["message"]["content"].as_str().unwrap().chars().count(),
        120_000
    );
    assert!(!json["message"]["truncated"].as_bool().unwrap());
}

#[tokio::test]
async fn thread_messages_stream_reconnect_skips_past_gap() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "stream").await;

    // 1005 messages makes the gap from 0 exceed the 1_000 threshold.
    seed_messages(&_db, &tid, 1005, "s").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            &format!("/api/threads/{tid}/messages/stream?since_seq=0&live=false"),
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = to_bytes(resp.into_body(), 64 * 1024).await.unwrap();
    let text = String::from_utf8_lossy(&body);
    assert!(text.contains("event: snapshot"), "body: {text}");
    assert!(text.contains("watermark"), "body: {text}");
}

#[tokio::test]
async fn thread_title_derived_from_first_send() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "New thread").await;

    let boundary = "----titleboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}--\r\n"
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

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["title"].as_str().unwrap(), "Hello world");
}

#[tokio::test]
async fn thread_title_does_not_overwrite_user_rename() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "New thread").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{tid}"),
            &cookie,
            r#"{"title":"Keep this"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let boundary = "----titleboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}--\r\n"
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

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["title"].as_str().unwrap(), "Keep this");
}

#[tokio::test]
async fn thread_send_stream_emits_thread_update() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "New thread").await;

    let boundary = "----titlestreamboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}--\r\n"
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

    let bytes = to_bytes(resp.into_body(), 64 * 1024).await.unwrap();
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("event: thread_update"), "body: {text}");

    let update_block = text
        .split("\n\n")
        .find(|b| b.contains("event: thread_update"))
        .expect("thread_update block");
    let data = update_block
        .lines()
        .find(|l| l.starts_with("data: "))
        .expect("thread_update data");
    let json: serde_json::Value =
        serde_json::from_str(&data[6..]).expect("valid thread_update json");
    assert_eq!(json["title"].as_str().unwrap(), "Hello world");
}

#[tokio::test]
async fn thread_title_only_changes_on_first_send() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "New thread").await;

    // First send sets the title.
    let boundary = "----titleboundary";
    let send = |prompt: &str| {
        let body = format!(
            "--{boundary}\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            {prompt}\r\n\
            --{boundary}--\r\n"
        );
        app.clone().oneshot(
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
    };

    let resp = send("First message").await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = send("Second message").await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["title"].as_str().unwrap(), "First message");
}

#[tokio::test]
async fn thread_title_preserves_custom_creation_title() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"Custom"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let tid: String = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    let boundary = "----titleboundary";
    let body = format!(
        "--{boundary}\r\n\
        Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
        Hello world\r\n\
        --{boundary}--\r\n"
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

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{tid}"), &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["title"].as_str().unwrap(), "Custom");
}

// ---------- per-thread provider selection ----------

#[tokio::test]
async fn thread_create_accepts_provider() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"title":"oc","provider":"opencode"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["provider_id"].as_str().unwrap(), "opencode");
}

#[tokio::test]
async fn thread_create_defaults_to_user_provider() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "default").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{id}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["provider_id"].as_str().unwrap(), "devin-cli");
}

#[tokio::test]
async fn thread_create_rejects_unknown_provider() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"provider":"not-real"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_provider_can_change_before_session() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "switch").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{id}"),
            &cookie,
            r#"{"provider":"opencode"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", &format!("/api/threads/{id}"), &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(json["thread"]["provider_id"].as_str().unwrap(), "opencode");
}

#[tokio::test]
async fn thread_provider_rejects_unknown_id() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "switch").await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{id}"),
            &cookie,
            r#"{"provider":"not-real"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_provider_is_locked_once_session_exists() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "locked").await;

    // Simulate a thread that already started a provider session.
    sqlx::query("UPDATE threads SET devin_session_id = 'ses_x' WHERE id = ?")
        .bind(&id)
        .execute(db.pool())
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{id}"),
            &cookie,
            r#"{"provider":"opencode"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Re-asserting the same provider is still allowed.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{id}"),
            &cookie,
            r#"{"provider":"devin-cli"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn thread_list_includes_provider_id() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;
    let id = make_thread(&app, &cookie, pid, "oc").await;

    // Switch the thread to a non-default provider.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            &format!("/api/threads/{id}"),
            &cookie,
            r#"{"provider":"opencode"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/threads", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let v = serde_json::from_str::<serde_json::Value>(&body).unwrap();
    let entry = v
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"].as_str().unwrap() == id)
        .unwrap();
    assert_eq!(entry["provider_id"].as_str().unwrap(), "opencode");
}

#[tokio::test]
async fn models_list_honors_provider_param() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/models?provider=opencode", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    // When the opencode binary is missing the static fallback list still
    // reports the OpenCode Zen model.
    assert!(body.contains("opencode/"), "body: {body}");
}

#[tokio::test]
async fn models_list_rejects_unknown_provider() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/models?provider=not-real", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn provider_version_honors_provider_param() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "GET",
            "/api/providers/version?provider=opencode",
            &cookie,
            "",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(body.contains(r#""provider_id":"opencode""#), "body: {body}");
    assert!(body.contains("OpenCode"), "body: {body}");
}

#[tokio::test]
async fn provider_commands_round_trip_through_me() {
    let (app, _db) = make_app().await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            "/api/auth/me",
            &cookie,
            r#"{"provider_id":"devin-cli","provider_command":"devin","provider_commands":{"opencode":"/opt/opencode"}}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(r#""opencode":"/opt/opencode""#),
        "body: {body}"
    );

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/auth/me", &cookie, ""))
        .await
        .unwrap();
    let body = body_str(resp.into_body()).await;
    assert!(
        body.contains(r#""opencode":"/opt/opencode""#),
        "body: {body}"
    );

    // Unknown provider ids inside the map are rejected.
    let resp = app
        .clone()
        .oneshot(authed(
            "PATCH",
            "/api/auth/me",
            &cookie,
            r#"{"provider_id":"devin-cli","provider_command":"devin","provider_commands":{"bogus":"x"}}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn thread_send_uses_thread_provider_command() {
    let (app, db) = make_app().await;
    let cookie = login(&app).await;
    let pid = create_project(&app, &cookie).await;

    // Give opencode a command that cannot run. The default provider keeps the
    // stub fallback via its empty command, so only the opencode thread fails.
    sqlx::query(
        "UPDATE users SET provider_commands = '{\"opencode\":\"/nonexistent/opencode\"}' WHERE username = 'owner'",
    )
    .execute(db.pool())
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(authed(
            "POST",
            "/api/threads",
            &cookie,
            &format!(r#"{{"project_id":{pid},"provider":"opencode"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = body_str(resp.into_body()).await;
    let id = serde_json::from_str::<serde_json::Value>(&body).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

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

/// Provider that reports cumulative token usage growing by
/// 100 input / 50 output tokens per call, so tests can verify per-turn
/// deltas reach the usage API.
struct UsageStubProvider {
    calls: std::sync::atomic::AtomicU64,
}

#[async_trait]
impl Provider for UsageStubProvider {
    fn id(&self) -> &str {
        "stub"
    }
    fn name(&self) -> &str {
        "Stub"
    }
    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        Ok(vec![])
    }
    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let n = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        if let Some(cb) = &req.options.session_callback {
            cb("usage-session".to_string()).await;
        }
        Ok(StartResponse {
            session_id: "usage-session".into(),
            reply: format!("echo: {}", req.prompt),
            thinking: String::new(),
            parts: vec![MessagePart::text(format!("echo: {}", req.prompt))],
            title: "Usage Thread".into(),
            usage: Some(devinorium::providers::UsageSnapshot {
                input_tokens: 100 * n,
                output_tokens: 50 * n,
                total_tokens: 150 * n,
                cost_amount: Some(0.5 * n as f64),
                cost_currency: Some("USD".into()),
                ..Default::default()
            }),
        })
    }
    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let n = self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        Ok(SendResponse {
            reply: format!("echo: {}", req.prompt),
            thinking: String::new(),
            parts: vec![MessagePart::text(format!("echo: {}", req.prompt))],
            usage: Some(devinorium::providers::UsageSnapshot {
                input_tokens: 100 * n,
                output_tokens: 50 * n,
                total_tokens: 150 * n,
                cost_amount: Some(0.5 * n as f64),
                cost_currency: Some("USD".into()),
                ..Default::default()
            }),
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

async fn send_prompt(app: &Router, cookie: &str, tid: &str, prompt: &str) {
    let boundary = "----testboundary";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{prompt}\r\n--{boundary}--\r\n"
    );
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/threads/{tid}/send"))
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", cookie)
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
}

#[tokio::test]
async fn usage_endpoint_reports_per_turn_deltas() {
    let (app, _db) = make_app_with_provider(Arc::new(UsageStubProvider {
        calls: std::sync::atomic::AtomicU64::new(0),
    }))
    .await;
    let cookie = login(&app).await;

    let pid = create_project(&app, &cookie).await;
    let tid = make_thread(&app, &cookie, pid, "Usage").await;

    send_prompt(&app, &cookie, &tid, "first").await;
    send_prompt(&app, &cookie, &tid, "second").await;

    let resp = app
        .clone()
        .oneshot(authed("GET", "/api/usage?days=7", &cookie, ""))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_str(resp.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();

    // Two turns: cumulative 150 then 300, so per-turn deltas are 150 + 150.
    assert_eq!(json["totals"]["total_tokens"], 300);
    assert_eq!(json["totals"]["input_tokens"], 200);
    assert_eq!(json["totals"]["output_tokens"], 100);
    assert_eq!(json["totals"]["records"], 2);
    assert_eq!(json["totals"]["costs"][0]["currency"], "USD");
    assert_eq!(json["totals"]["costs"][0]["amount"], 1.0);

    let buckets = json["buckets"].as_array().unwrap();
    assert_eq!(buckets.len(), 1, "one (day, provider, model) bucket");
    assert_eq!(buckets[0]["provider_id"], "devin-cli");
    assert_eq!(buckets[0]["model"], "stub-1");
    assert_eq!(buckets[0]["total_tokens"], 300);
    assert_eq!(buckets[0]["records"], 2);
}

#[tokio::test]
async fn usage_endpoint_requires_auth() {
    let (app, _db) = make_app().await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/api/usage")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}
