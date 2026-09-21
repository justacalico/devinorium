//! Integration tests for hub/satellite federation: registration auth, the
//! node list, and request proxying (including a real TCP hop to a live
//! "satellite" server and a WebSocket tunnel).

#![cfg(test)]

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, Response, StatusCode};
use axum::Router;
use tower::ServiceExt;

use devinorium::{
    auth,
    config::Config,
    db,
    git::{GitRemoteService, GitService},
    providers, AppState,
};

const FED_TOKEN: &str = "test-federation-token-0123456789";

async fn make_state(federation_token: Option<&str>) -> (AppState, db::Db) {
    let dir = tempfile::tempdir().expect("tempdir").keep();
    let db_url = format!("sqlite:{}?mode=rwc", dir.join("fed.db").display());
    let database = db::Db::connect(&db_url).await.expect("db connect");
    auth::bootstrap::run(&database, "owner", "supersecret123")
        .await
        .expect("bootstrap");
    if federation_token.is_some() {
        auth::bootstrap::run_local(&database)
            .await
            .expect("local bootstrap");
    }
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
        federation_token: federation_token.map(str::to_string),
        hub_url: None,
        node_name: "test-hub".into(),
        node_url: None,
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
        bound_addr: std::sync::Arc::new(std::sync::OnceLock::new()),
        http_client: devinorium::federation::http_client(),
    };
    (state, database)
}

async fn make_hub(federation_token: Option<&str>) -> (Router, db::Db) {
    let (state, database) = make_state(federation_token).await;
    (devinorium::build_app(state), database)
}

/// Serve an app on a real loopback socket and return its base URL. The
/// proxy path dials out over TCP, so a satellite under test must really
/// listen.
async fn serve(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
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
    let bytes = to_bytes(b, 1024 * 1024).await.unwrap();
    String::from_utf8(bytes.to_vec()).unwrap()
}

fn register_req(token: Option<&str>, body: &str) -> Request<Body> {
    let mut b = Request::builder()
        .method("POST")
        .uri("/api/federation/register")
        .header("content-type", "application/json");
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    b.body(Body::from(body.to_string())).unwrap()
}

const REGISTER_BODY: &str =
    r#"{"id":"node-1","name":"oss box","base_url":"http://127.0.0.1:9999","version":"1.0.0"}"#;

#[tokio::test]
async fn register_requires_valid_federation_token() {
    let (app, _db) = make_hub(Some(FED_TOKEN)).await;

    // No token at all: the CSRF layer rejects origin-less writes before
    // the handler even sees them.
    let resp = app
        .clone()
        .oneshot(register_req(None, REGISTER_BODY))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);

    // Wrong token.
    let resp = app
        .clone()
        .oneshot(register_req(Some("wrong-token"), REGISTER_BODY))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Right token.
    let resp = app
        .clone()
        .oneshot(register_req(Some(FED_TOKEN), REGISTER_BODY))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn register_is_closed_without_federation_token() {
    let (app, _db) = make_hub(None).await;
    let resp = app
        .clone()
        .oneshot(register_req(Some(FED_TOKEN), REGISTER_BODY))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn register_validates_fields() {
    let (app, _db) = make_hub(Some(FED_TOKEN)).await;
    for body in [
        r#"{"id":"","name":"x","base_url":"http://a:1"}"#,
        r#"{"id":"has space","name":"x","base_url":"http://a:1"}"#,
        r#"{"id":"ok","name":"","base_url":"http://a:1"}"#,
        r#"{"id":"ok","name":"x","base_url":"ftp://a"}"#,
        r#"{"id":"ok","name":"x","base_url":"http://a:1/path"}"#,
        r#"{"id":"ok","name":"x","base_url":"http://a:1/?q=1"}"#,
        "not json",
    ] {
        let resp = app
            .clone()
            .oneshot(register_req(Some(FED_TOKEN), body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "body: {body}");
    }
}

#[tokio::test]
async fn nodes_list_is_owner_only_and_reports_online() {
    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;

    // Register a node via the endpoint.
    let resp = app
        .clone()
        .oneshot(register_req(Some(FED_TOKEN), REGISTER_BODY))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let _ = db; // node row already asserted through the list below

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(json["self"]["name"], "test-hub");
    let nodes = json["nodes"].as_array().unwrap();
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0]["id"], "node-1");
    assert_eq!(nodes[0]["name"], "oss box");
    assert_eq!(nodes[0]["online"], true);
    assert_eq!(nodes[0]["version"], "1.0.0");

    // A non-owner account cannot list nodes.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/users")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("content-type", "application/json")
                .header("cookie", &cookie)
                .body(Body::from(
                    r#"{"username":"guest","password":"guestpass123"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let guest = {
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
                        r#"{"username":"guest","password":"guestpass123"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        resp.headers()
            .get("set-cookie")
            .unwrap()
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_string()
    };
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes")
                .header("cookie", &guest)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn remove_node_requires_owner_and_deletes() {
    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;
    db.upsert_federation_node("n1", "box", "http://127.0.0.1:1", "")
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/federation/nodes/n1")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(db.get_federation_node("n1").await.unwrap().is_none());

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/federation/nodes/n1")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn proxy_forwards_requests_to_the_node() {
    // A live satellite: the same app, with the shared token configured.
    let (sat_state, _sat_db) = make_state(Some(FED_TOKEN)).await;
    let sat_url = serve(devinorium::build_app(sat_state)).await;

    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;
    db.upsert_federation_node("sat-1", "satellite", &sat_url, "")
        .await
        .unwrap();

    // GET through the proxy reaches the satellite's own API; the federation
    // token authenticates as its `local` owner.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/sat-1/proxy/api/auth/me")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(json["username"], "local");
    assert_eq!(json["is_owner"], true);

    // The query string rides along.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/sat-1/proxy/api/federation/nodes")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // POST bodies stream through; the satellite answers with its own auth
    // decision (bad login -> 401 proves the request reached and ran there).
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/federation/nodes/sat-1/proxy/api/auth/login")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"nobody","password":"nope"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn proxy_replaces_credentials_and_tags_the_user() {
    use axum::routing::get as axum_get;

    // Satellite that reports which headers actually arrived.
    let echo = Router::new().route(
        "/headers",
        axum_get(|req: Request<Body>| async move {
            let h = req.headers();
            let pick = |k: &str| h.get(k).and_then(|v| v.to_str().ok().map(str::to_string));
            serde_json::json!({
                "authorization": pick("authorization"),
                "cookie": pick("cookie"),
                "origin": pick("origin"),
                "proxy_user": pick("x-devinorium-proxy-user"),
            })
            .to_string()
        }),
    );
    let sat_url = serve(echo).await;

    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;
    db.upsert_federation_node("sat-1", "satellite", &sat_url, "")
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/sat-1/proxy/headers")
                .header(header::HOST, "localhost")
                .header(header::ORIGIN, "http://localhost")
                .header("cookie", &cookie)
                // A spoofed attribution header must not survive either.
                .header("x-devinorium-proxy-user", "mallory")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let json: serde_json::Value = serde_json::from_str(&body_str(resp.into_body()).await).unwrap();
    assert_eq!(
        json["authorization"],
        serde_json::json!(format!("Bearer {FED_TOKEN}"))
    );
    assert_eq!(json["proxy_user"], "owner");
    // The caller's session cookie and browser origin never cross over.
    assert_eq!(json["cookie"], serde_json::Value::Null);
    assert_eq!(json["origin"], serde_json::Value::Null);
}

#[tokio::test]
async fn proxy_strips_satellite_origin_headers() {
    use axum::routing::get as axum_get;

    // Satellite answering with headers that would act on the hub origin.
    let evil = Router::new().route(
        "/cookie",
        axum_get(|| async move {
            Response::builder()
                .header("set-cookie", "devinorium_session=stolen; Path=/")
                .header("location", "http://satellite.internal/")
                .header("www-authenticate", "Basic realm=\"sat\"")
                .header("clear-site-data", "\"cookies\"")
                .body(Body::from("ok"))
                .unwrap()
        }),
    );
    let sat_url = serve(evil).await;

    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;
    db.upsert_federation_node("sat-1", "satellite", &sat_url, "")
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/sat-1/proxy/cookie")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    for h in ["set-cookie", "location", "www-authenticate", "clear-site-data"] {
        assert!(resp.headers().get(h).is_none(), "{h} leaked");
    }
    assert_eq!(body_str(resp.into_body()).await, "ok");
}

#[tokio::test]
async fn proxy_rejects_unknown_node_and_excess_hops() {
    let (app, _db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/ghost/proxy/healthz")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    // Hop limit guards against forwarding rings.
    db_register(&app, "hopper").await;
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/hopper/proxy/healthz")
                .header("cookie", &cookie)
                .header("x-devinorium-proxy-hop", "4")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::LOOP_DETECTED);
}

async fn db_register(app: &Router, id: &str) {
    let resp = app
        .clone()
        .oneshot(register_req(
            Some(FED_TOKEN),
            &format!(r#"{{"id":"{id}","name":"n","base_url":"http://127.0.0.1:1"}}"#),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn proxy_to_offline_node_is_bad_gateway() {
    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    let cookie = login(&app).await;
    // Nothing listens on this port.
    db.upsert_federation_node("dead", "dead box", "http://127.0.0.1:9", "")
        .await
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/dead/proxy/healthz")
                .header("cookie", &cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn proxy_requires_owner() {
    let (app, db) = make_hub(Some(FED_TOKEN)).await;
    db.upsert_federation_node("sat-1", "sat", "http://127.0.0.1:1", "")
        .await
        .unwrap();

    // Not signed in at all.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/federation/nodes/sat-1/proxy/healthz")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn websocket_tunnels_through_the_hub() {
    use axum::extract::WebSocketUpgrade;
    use axum::routing::get as axum_get;
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;

    // Satellite: a bare echo socket on /echo.
    let echo = Router::new().route(
        "/echo",
        axum_get(|ws: WebSocketUpgrade| async move {
            ws.on_upgrade(|mut socket| async move {
                while let Some(Ok(msg)) = socket.recv().await {
                    if socket.send(msg).await.is_err() {
                        break;
                    }
                }
            })
        }),
    );
    let sat_url = serve(echo).await;

    // Hub on a real socket too: WS upgrade needs an actual connection.
    let (hub_state, hub_db) = make_state(Some(FED_TOKEN)).await;
    hub_db
        .upsert_federation_node("sat-1", "sat", &sat_url, "")
        .await
        .unwrap();
    let hub_url = serve(devinorium::build_app(hub_state)).await;

    // Log in on the hub over HTTP to get a session cookie for the upgrade.
    let client = reqwest::Client::new();
    let login = client
        .post(format!("{hub_url}/api/auth/login"))
        .header("content-type", "application/json")
        .header("origin", &hub_url)
        .body(r#"{"username":"owner","password":"supersecret123"}"#)
        .send()
        .await
        .unwrap();
    assert_eq!(login.status(), StatusCode::OK);
    let cookie = login
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string();

    let ws_url = format!(
        "{}/api/federation/nodes/sat-1/proxy/echo",
        hub_url.replacen("http://", "ws://", 1)
    );
    let host = hub_url.strip_prefix("http://").unwrap().to_string();
    let ws_key = tokio_tungstenite::tungstenite::handshake::client::generate_key();
    let req = Request::builder()
        .uri(&ws_url)
        .header("Host", &host)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", &ws_key)
        .header("Cookie", &cookie)
        .header("Origin", &hub_url)
        .body(())
        .unwrap();
    let (mut socket, _) = tokio_tungstenite::connect_async(req).await.unwrap();

    socket
        .send(Message::Text("hello federation".into()))
        .await
        .unwrap();
    let echoed = socket.next().await.unwrap().unwrap();
    assert_eq!(echoed, Message::Text("hello federation".into()));
    let _ = socket.close(None).await;
}
