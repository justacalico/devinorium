//! Integration tests for the Tailscale status and serve-toggle endpoints.

#![cfg(test)]

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use tower::ServiceExt;

use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers, AppState,
};

const MISSING_BIN: &str = "definitely-not-a-tailscale-binary-xyz";

async fn make_app(
    tailscale_bin: &str,
    local_token: Option<&str>,
    port: u16,
) -> (Router, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("tailscale.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    if local_token.is_some() {
        auth::bootstrap::run_local(&database)
            .await
            .expect("local bootstrap");
    }

    let cfg = Config {
        host: "127.0.0.1".into(),
        port,
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
        local_token: local_token.map(str::to_string),
        tailscale_bin: tailscale_bin.into(),
        tailscale_serve: false,
        tailscale_serve_port: 443,
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
        tailscale: devinorium::tailscale::Tailscale::new(tailscale_bin),
    };
    (devinorium::build_app(state), database)
}

async fn login_token(app: &Router) -> String {
    let resp = app
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
    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    v["token"].as_str().unwrap().to_string()
}

async fn get_status(app: &Router, bearer: &str) -> (StatusCode, serde_json::Value) {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/tailscale")
                .header("authorization", format!("Bearer {bearer}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(serde_json::json!({})),
    )
}

async fn put_serve(app: &Router, bearer: &str, enabled: bool) -> (StatusCode, serde_json::Value) {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri("/api/tailscale/serve")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {bearer}"))
                .body(Body::from(format!(r#"{{"enabled":{enabled}}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(serde_json::json!({})),
    )
}

#[tokio::test]
async fn status_requires_auth() {
    let (app, _db) = make_app(MISSING_BIN, None, 7878).await;
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/tailscale")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn status_reports_missing_cli() {
    let (app, _db) = make_app(MISSING_BIN, None, 7878).await;
    let token = login_token(&app).await;
    let (status, json) = get_status(&app, &token).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["installed"], false);
    assert_eq!(json["serve_enabled"], false);
    assert_eq!(json["local_mode"], false);
    assert_eq!(json["endpoints"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn serve_toggle_requires_owner() {
    let (app, db) = make_app(MISSING_BIN, None, 7878).await;
    db.create_user(db::NewUser {
        username: "member".into(),
        password_hash: auth::password::hash("memberpass123").unwrap(),
        is_owner: false,
    })
    .await
    .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .header("host", "localhost")
                .header("origin", "http://localhost")
                .body(Body::from(
                    r#"{"username":"member","password":"memberpass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let member_token = v["token"].as_str().unwrap().to_string();

    // Members can read the status but not flip the mapping.
    let (status, _) = get_status(&app, &member_token).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = put_serve(&app, &member_token, true).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn serve_enable_returns_404_without_cli() {
    let (app, _db) = make_app(MISSING_BIN, None, 7878).await;
    let token = login_token(&app).await;
    let (status, json) = put_serve(&app, &token, true).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(json["error"], "tailscale CLI is not installed");
}

#[tokio::test]
async fn local_mode_disables_the_feature() {
    let (app, _db) = make_app(MISSING_BIN, Some("test-local-token-0123456789"), 7878).await;
    let bearer = "test-local-token-0123456789";

    let (status, json) = get_status(&app, bearer).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["local_mode"], true);
    assert_eq!(json["installed"], false);

    let (status, _) = put_serve(&app, bearer, true).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[cfg(unix)]
mod fake_cli {
    use super::*;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    /// A `tailscale` stand-in that answers `status`, remembers whether a
    /// serve mapping was installed, and proxies `serve status` accordingly.
    /// The MagicDNS name is `devbox.localhost` so the HTTPS probe resolves
    /// instantly instead of waiting on real DNS for a .ts.net name.
    fn make_fake(dir: &std::path::Path) -> std::path::PathBuf {
        let state_file = dir.join("serve-state.json");
        let script = format!(
            "#!/bin/sh\n\
             if [ \"$1\" = status ]; then\n\
               echo '{{\"BackendState\":\"Running\",\"Self\":{{\"DNSName\":\"devbox.localhost.\",\"TailscaleIPs\":[\"100.96.1.2\",\"fd7a::1\"]}}}}'\n\
             elif [ \"$1\" = serve ] && [ \"$2\" = status ]; then\n\
               if [ -f '{0}' ]; then cat '{0}'; else echo '{{}}'; fi\n\
             elif [ \"$1\" = serve ] && [ \"$3\" = off ]; then\n\
               rm -f '{0}'\n\
             elif [ \"$1\" = serve ]; then\n\
               echo '{{\"Web\":{{\"devbox.localhost:443\":{{\"Handlers\":{{\"/\":{{\"Proxy\":\"'$4'\"}}}}}}}}}}' > '{0}'\n\
             fi\n\
             exit 0\n",
            state_file.display()
        );
        let path = dir.join("tailscale");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(script.as_bytes()).unwrap();
        let mut perms = f.metadata().unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    #[tokio::test]
    async fn status_reports_identity_and_endpoints() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878).await;
        let token = login_token(&app).await;

        let (status, json) = get_status(&app, &token).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["installed"], true);
        assert_eq!(json["magic_dns_name"], "devbox.localhost");
        assert_eq!(json["tailnet_ipv4"], serde_json::json!(["100.96.1.2"]));
        assert_eq!(json["serve_enabled"], false);

        let endpoints = json["endpoints"].as_array().unwrap();
        // Loopback bind: tailnet-IP endpoints exist but are not reachable.
        assert!(endpoints
            .iter()
            .any(|e| e["url"] == "http://100.96.1.2:7878" && e["reachable"] == false));
        assert!(endpoints
            .iter()
            .any(|e| e["url"] == "http://devbox.localhost:7878"));
    }

    #[tokio::test]
    async fn serve_toggle_on_and_off() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878).await;
        let token = login_token(&app).await;

        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], true);
        assert_eq!(json["https_url"], "https://devbox.localhost/");
        // Nothing answers on devbox.localhost:443, so the probe fails fast.
        assert_eq!(json["https_reachable"], false);
        assert!(json["endpoints"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["kind"] == "tailscale-https"
                && e["url"] == "https://devbox.localhost/"));

        let (status, json) = put_serve(&app, &token, false).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], false);
        assert_eq!(json["https_url"], serde_json::Value::Null);
    }
}
