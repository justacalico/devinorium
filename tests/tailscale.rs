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

/// `serve_port` seeds the persisted setting, matching what an owner stored
/// through the API on a previous run.
async fn make_app(
    tailscale_bin: &str,
    local_token: Option<&str>,
    port: u16,
    serve_port: u16,
) -> (Router, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("tailscale.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    database
        .set_tailscale_serve(false, Some(serve_port))
        .await
        .expect("seed serve port");
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
    put_serve_with_port(app, bearer, enabled, None).await
}

async fn put_serve_with_port(
    app: &Router,
    bearer: &str,
    enabled: bool,
    port: Option<u16>,
) -> (StatusCode, serde_json::Value) {
    let body = match port {
        Some(p) => format!(r#"{{"enabled":{enabled},"port":{p}}}"#),
        None => format!(r#"{{"enabled":{enabled}}}"#),
    };
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri("/api/tailscale/serve")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {bearer}"))
                .body(Body::from(body))
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
    let (app, _db) = make_app(MISSING_BIN, None, 7878, 443).await;
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
    let (app, _db) = make_app(MISSING_BIN, None, 7878, 443).await;
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
    let (app, db) = make_app(MISSING_BIN, None, 7878, 443).await;
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
    let (app, _db) = make_app(MISSING_BIN, None, 7878, 443).await;
    let token = login_token(&app).await;
    let (status, json) = put_serve(&app, &token, true).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(json["error"], "tailscale CLI is not installed");
}

#[tokio::test]
async fn local_mode_disables_the_feature() {
    let (app, _db) = make_app(MISSING_BIN, Some("test-local-token-0123456789"), 7878, 443).await;
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

    /// A serve port nothing listens on, so the HTTPS probe is refused
    /// instantly instead of depending on whatever runs on 443.
    const SERVE_PORT: u16 = 45999;

    /// A `tailscale` stand-in that answers `status`, tracks one serve
    /// mapping per https port under `serve.d/`, and renders them as the
    /// `Web` map `serve status --json` would produce. The MagicDNS name is
    /// `devbox.localhost` so the HTTPS probe resolves instantly instead of
    /// waiting on real DNS for a .ts.net name.
    fn make_fake(dir: &std::path::Path) -> std::path::PathBuf {
        let state_dir = dir.join("serve.d");
        std::fs::create_dir_all(&state_dir).unwrap();
        let script = format!(
            "#!/bin/sh\n\
             if [ \"$1\" = status ]; then\n\
               echo '{{\"BackendState\":\"Running\",\"Self\":{{\"DNSName\":\"devbox.localhost.\",\"TailscaleIPs\":[\"100.96.1.2\",\"fd7a::1\"]}}}}'\n\
             elif [ \"$1\" = serve ] && [ \"$2\" = status ]; then\n\
               printf '{{\"Web\":{{'\n\
               sep=''\n\
               for f in '{0}'/*; do\n\
                 [ -f \"$f\" ] || continue\n\
                 printf '%s\"devbox.localhost:%s\":{{\"Handlers\":{{\"/\":{{\"Proxy\":\"%s\"}}}}}}' \"$sep\" \"${{f##*/}}\" \"$(cat \"$f\")\"\n\
                 sep=','\n\
               done\n\
               printf '}}}}'\n\
             elif [ \"$1\" = serve ] && [ \"$3\" = off ]; then\n\
               rm -f '{0}'/\"${{2#--https=}}\"\n\
             elif [ \"$1\" = serve ]; then\n\
               echo \"$4\" > '{0}'/\"${{3#--https=}}\"\n\
             fi\n\
             exit 0\n",
            state_dir.display()
        );
        let path = dir.join("tailscale");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(script.as_bytes()).unwrap();
        let mut perms = f.metadata().unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    /// Whether the fake tailscaled has a serve mapping on `https_port`.
    fn mapping_exists(dir: &std::path::Path, https_port: u16) -> bool {
        dir.join("serve.d").join(https_port.to_string()).exists()
    }

    #[tokio::test]
    async fn status_reports_identity_and_endpoints() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
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
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;

        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], true);
        assert_eq!(json["serve_port"], SERVE_PORT as i64);
        assert_eq!(
            json["https_url"],
            format!("https://devbox.localhost:{SERVE_PORT}/")
        );
        // Nothing answers on devbox.localhost:SERVE_PORT, so the probe fails fast.
        assert_eq!(json["https_reachable"], false);
        assert!(json["endpoints"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["kind"] == "tailscale-https"
                && e["url"] == format!("https://devbox.localhost:{SERVE_PORT}/")));

        let (status, json) = put_serve(&app, &token, false).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], false);
        assert_eq!(json["https_url"], serde_json::Value::Null);
    }

    #[tokio::test]
    async fn serve_toggle_persists_the_desired_state() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;

        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_desired"], true);
        assert_eq!(
            db.get_tailscale_serve().await.unwrap(),
            (true, SERVE_PORT),
            "enable must persist so a restart re-applies the mapping"
        );

        let (status, json) = put_serve(&app, &token, false).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_desired"], false);
        // Disabling keeps the stored port for the next enable.
        assert_eq!(db.get_tailscale_serve().await.unwrap(), (false, SERVE_PORT));
    }

    #[tokio::test]
    async fn serve_enable_with_another_port_moves_the_mapping() {
        const NEW_PORT: u16 = SERVE_PORT - 1;
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;

        let (status, _) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::OK);

        let (status, json) = put_serve_with_port(&app, &token, true, Some(NEW_PORT)).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], true);
        assert_eq!(json["serve_port"], NEW_PORT as i64);
        assert_eq!(
            json["https_url"],
            format!("https://devbox.localhost:{NEW_PORT}/")
        );
        assert_eq!(db.get_tailscale_serve().await.unwrap(), (true, NEW_PORT));
        // The move swapped ports instead of stacking them.
        assert!(mapping_exists(dir.path(), NEW_PORT));
        assert!(!mapping_exists(dir.path(), SERVE_PORT));
    }

    #[tokio::test]
    async fn serve_enable_rejects_port_zero() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;
        let (status, _) = put_serve_with_port(&app, &token, true, Some(0)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    /// Seed the fake tailscaled with a mapping that does not proxy to this
    /// server.
    fn seed_foreign_mapping(dir: &std::path::Path, https_port: u16) {
        std::fs::write(
            dir.join("serve.d").join(https_port.to_string()),
            "http://127.0.0.1:9999",
        )
        .unwrap();
    }

    #[tokio::test]
    async fn serve_enable_refuses_a_foreign_mapping_on_the_configured_port() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        seed_foreign_mapping(dir.path(), SERVE_PORT);
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;

        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert!(json["error"].as_str().unwrap().contains("in use"));
        // The foreign mapping is still there.
        assert!(mapping_exists(dir.path(), SERVE_PORT));
    }

    #[tokio::test]
    async fn serve_disable_leaves_foreign_mappings_alone() {
        let dir = tempfile::tempdir().unwrap();
        let bin = make_fake(dir.path());
        seed_foreign_mapping(dir.path(), SERVE_PORT);
        let (app, _db) = make_app(&bin.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;

        let (status, json) = put_serve(&app, &token, false).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["serve_enabled"], false);
        // `serve off` was never invoked: somebody else's mapping survives.
        assert!(mapping_exists(dir.path(), SERVE_PORT));
    }

    #[tokio::test]
    async fn serve_enable_fails_when_serve_status_is_unreadable() {
        // `serve status` fails while `serve` itself would succeed; enabling
        // must refuse rather than guess the port is free and clobber a
        // foreign mapping it cannot see.
        let dir = tempfile::tempdir().unwrap();
        let state_file = dir.path().join("serve-state.json");
        let script = format!(
            "#!/bin/sh\n\
             if [ \"$1\" = status ]; then\n\
               echo '{{\"BackendState\":\"Running\",\"Self\":{{\"DNSName\":\"devbox.localhost.\",\"TailscaleIPs\":[\"100.96.1.2\"]}}}}'\n\
             elif [ \"$1\" = serve ] && [ \"$2\" = status ]; then\n\
               echo 'broken pipe' >&2; exit 1\n\
             elif [ \"$1\" = serve ]; then\n\
               echo '{{}}' > '{0}'\n\
             fi\n\
             exit 0\n",
            state_file.display()
        );
        let path = dir.path().join("tailscale");
        std::fs::write(&path, script).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();

        let (app, _db) = make_app(&path.to_string_lossy(), None, 7878, SERVE_PORT).await;
        let token = login_token(&app).await;
        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::BAD_GATEWAY);
        assert!(
            !state_file.exists(),
            "enable must not create a mapping it cannot verify"
        );
        assert!(!json.to_string().contains("broken pipe"));
    }

    #[tokio::test]
    async fn serve_errors_never_leak_stderr() {
        // `serve` fails with a secret-looking stderr; the API must return the
        // classified diagnostic, not the raw output.
        let dir = tempfile::tempdir().unwrap();
        let script = "#!/bin/sh\n\
            if [ \"$1\" = status ]; then\n\
              echo '{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"devbox.localhost.\",\"TailscaleIPs\":[\"100.96.1.2\"]}}'\n\
            elif [ \"$1\" = serve ]; then\n\
              echo 'tskey-auth-SECRET-1234' >&2\n\
              exit 1\n\
            fi\n\
            exit 0\n";
        let path = dir.path().join("tailscale");
        std::fs::write(&path, script).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();

        let (app, _db) = make_app(&path.to_string_lossy(), None, 7878, 443).await;
        let token = login_token(&app).await;
        let (status, json) = put_serve(&app, &token, true).await;
        assert_eq!(status, StatusCode::BAD_GATEWAY);
        let body = json.to_string();
        assert!(
            !body.contains("tskey-auth-SECRET-1234"),
            "stderr leaked: {body}"
        );
        assert!(
            body.contains("unknown"),
            "expected classified diagnostic: {body}"
        );
    }
}
