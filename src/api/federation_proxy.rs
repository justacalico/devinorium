//! Reverse proxy from a hub to a registered satellite node.
//!
//! Every API path can be reached through
//! `/api/federation/nodes/:id/proxy/<path>`, so a client that picks a node
//! simply prefixes its calls and the hub forwards them to the satellite
//! with the shared federation token as the bearer credential. Plain
//! requests stream both ways (SSE included); `Upgrade: websocket` requests
//! are tunneled frame-for-frame so the terminal keeps working.

use axum::body::Body;
use axum::extract::{Request, State, WebSocketUpgrade};
use axum::http::{header, HeaderMap, HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures::{SinkExt, StreamExt};

use std::time::Duration;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::federation_nodes::FederationNodeRow;
use crate::federation::{MAX_PROXY_HOPS, PROXY_HOP_HEADER, PROXY_USER_HEADER};
use crate::security::ip::ClientIp;
use crate::AppState;

/// Cap on dialing an upstream WebSocket; a blackholed satellite should fail
/// the tunnel quickly instead of parking the task on the OS TCP timeout.
const WS_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Headers that must not cross the proxy boundary in either direction.
/// Hop-by-hop fields belong to the connection, and credential/origin fields
/// are rewritten so the caller's session never leaks to the satellite and
/// the satellite never mistakes a browser Origin for its own.
const STRIPPED_REQUEST_HEADERS: &[&str] = &[
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "keep-alive",
    "te",
    "trailer",
    "trailers",
    "upgrade",
    "authorization",
    "cookie",
    "origin",
    "referer",
    "accept-encoding",
    "forwarded",
    "x-forwarded-for",
    "x-forwarded-proto",
    "x-forwarded-host",
    "x-forwarded-port",
    "x-forwarded-server",
    "x-forwarded-scheme",
    "x-real-ip",
    "proxy-authorization",
    "proxy-connection",
    PROXY_HOP_HEADER,
    PROXY_USER_HEADER,
];

/// Response headers that must not reach the hub's client. Beyond framing
/// headers this drops anything that would act on the hub's origin: a
/// satellite `Set-Cookie` would overwrite the caller's hub session cookie,
/// `Location` would send the browser around the proxy, and
/// `WWW-Authenticate`/`Clear-Site-Data`/`Alt-Svc` all target the wrong
/// origin once relayed.
const STRIPPED_RESPONSE_HEADERS: &[&str] = &[
    "connection",
    "transfer-encoding",
    "keep-alive",
    "trailer",
    "trailers",
    "upgrade",
    "content-length",
    "set-cookie",
    "clear-site-data",
    "www-authenticate",
    "alt-svc",
    "location",
];

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response()
}

fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
}

fn bad_gateway(msg: impl Into<String>) -> Response {
    (StatusCode::BAD_GATEWAY, Json(ApiError::new(msg.into()))).into_response()
}

/// Entry point for both proxy routes (`/proxy` and `/proxy/*path`). The
/// wildcard captures everything after `proxy/` and may be empty on the
/// bare route, which axum reports as a one-element path.
pub async fn proxy(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    ws: Option<WebSocketUpgrade>,
    req: Request,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }

    // The hop counter is a loop guard: a ring of hubs each forwarding to
    // the next would otherwise spin a request forever.
    let hop = req
        .headers()
        .get(PROXY_HOP_HEADER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(0);
    if hop >= MAX_PROXY_HOPS {
        return (
            StatusCode::LOOP_DETECTED,
            Json(ApiError::new("proxy hop limit reached")),
        )
            .into_response();
    }

    // Pull the node id and sub-path out of the URI rather than relying on
    // Path<(...)>: the same handler serves both the bare `/proxy` route and
    // the wildcard one.
    let (id, sub_path) = match split_proxy_path(req.uri().path()) {
        Some(parts) => parts,
        None => return not_found(),
    };

    let node = match state.db.get_federation_node(&id).await {
        Ok(Some(n)) => n,
        Ok(None) => return not_found(),
        Err(e) => return map_err_internal(e).into_response(),
    };

    let Some(token) = state.config.federation_token.clone() else {
        // Without the shared token the hub cannot authenticate to the
        // satellite at all; treat it as federation being off.
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiError::new("federation is not configured on this server")),
        )
            .into_response();
    };

    if let Some(ws) = ws {
        let query = req.uri().query().map(str::to_string);
        let client_ip = req
            .extensions()
            .get::<ClientIp>()
            .map(|ip| ip.0.to_string());
        return ws.on_upgrade(move |socket| async move {
            tunnel_websocket(
                socket,
                &node,
                &sub_path,
                query.as_deref(),
                &token,
                hop,
                client_ip,
                user.username,
            )
            .await;
        });
    }

    proxy_http(state, req, &node, &sub_path, &token, hop, &user.username).await
}

/// Split `/api/federation/nodes/<id>/proxy[/rest...]` into `(id, rest)`.
/// `rest` keeps its inner slashes and never starts with `/`.
fn split_proxy_path(path: &str) -> Option<(String, String)> {
    let rest = path.strip_prefix("/api/federation/nodes/")?;
    let (id, rest) = rest.split_once("/proxy")?;
    if id.is_empty() || id.contains('/') {
        return None;
    }
    let sub = rest.strip_prefix('/').unwrap_or("");
    if !rest.is_empty() && !rest.starts_with('/') {
        // ".../proxyX" is not the proxy route.
        return None;
    }
    Some((id.to_string(), sub.to_string()))
}

/// Build the absolute URL on the satellite for a proxied request.
fn node_url(node: &FederationNodeRow, sub_path: &str, query: Option<&str>) -> String {
    let base = node.base_url.trim_end_matches('/');
    let mut url = format!("{base}/{sub_path}");
    if let Some(q) = query {
        if !q.is_empty() {
            url.push('?');
            url.push_str(q);
        }
    }
    url
}

fn is_stripped_request(name: &HeaderName) -> bool {
    let s = name.as_str();
    STRIPPED_REQUEST_HEADERS.contains(&s) || s.starts_with("sec-websocket-")
}

async fn proxy_http(
    state: AppState,
    req: Request,
    node: &FederationNodeRow,
    sub_path: &str,
    token: &str,
    hop: u32,
    username: &str,
) -> Response {
    let url = node_url(node, sub_path, req.uri().query());
    let client_ip = req
        .extensions()
        .get::<ClientIp>()
        .map(|ip| ip.0.to_string());

    let mut out = state
        .http_client
        .request(req.method().clone(), &url)
        .bearer_auth(token)
        .header(PROXY_HOP_HEADER, (hop + 1).to_string());
    if let Ok(v) = axum::http::HeaderValue::from_str(username) {
        out = out.header(PROXY_USER_HEADER, v);
    }
    if let Some(ip) = client_ip {
        out = out.header("x-forwarded-for", ip);
    }
    for (name, value) in req.headers() {
        if !is_stripped_request(name) {
            out = out.header(name, value);
        }
    }

    let body = req.into_body().into_data_stream();
    let res = match out.body(reqwest::Body::wrap_stream(body)).send().await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(node = %node.id, "federation proxy upstream failed: {e}");
            return bad_gateway("node unreachable");
        }
    };

    let status = res.status();
    let mut headers = HeaderMap::new();
    for (name, value) in res.headers() {
        if !STRIPPED_RESPONSE_HEADERS.contains(&name.as_str()) {
            headers.append(name.clone(), value.clone());
        }
    }

    let mut builder = Response::builder().status(status);
    *builder.headers_mut().unwrap() = headers;
    builder
        .body(Body::from_stream(res.bytes_stream()))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// Open the upstream WebSocket and pump frames both ways until either side
/// closes. The upstream connect happens after the client upgrade so a dead
/// satellite just yields a closed socket rather than a failed HTTP call.
async fn tunnel_websocket(
    socket: axum::extract::ws::WebSocket,
    node: &FederationNodeRow,
    sub_path: &str,
    query: Option<&str>,
    token: &str,
    hop: u32,
    client_ip: Option<String>,
    username: String,
) {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let mut url = node_url(node, sub_path, query);
    if let Some(rest) = url.strip_prefix("https://") {
        url = format!("wss://{rest}");
    } else if let Some(rest) = url.strip_prefix("http://") {
        url = format!("ws://{rest}");
    }

    let upstream = async move {
        let mut request = url.into_client_request()?;
        let headers = request.headers_mut();
        if let Ok(v) = format!("Bearer {token}").parse() {
            headers.insert(header::AUTHORIZATION, v);
        }
        if let Ok(v) = (hop + 1).to_string().parse() {
            headers.insert(HeaderName::from_static(PROXY_HOP_HEADER), v);
        }
        if let Ok(v) = username.parse() {
            headers.insert(HeaderName::from_static(PROXY_USER_HEADER), v);
        }
        if let Some(ip) = client_ip {
            if let Ok(v) = ip.parse() {
                headers.insert(header::HeaderName::from_static("x-forwarded-for"), v);
            }
        }
        tokio_tungstenite::connect_async(request).await
    };

    let (upstream, _) = match tokio::time::timeout(WS_CONNECT_TIMEOUT, upstream).await {
        Ok(Ok(pair)) => pair,
        Ok(Err(e)) => {
            tracing::warn!(node = %node.id, "federation ws upstream failed: {e}");
            let _ = socket.close().await;
            return;
        }
        Err(_) => {
            tracing::warn!(node = %node.id, "federation ws upstream timed out");
            let _ = socket.close().await;
            return;
        }
    };

    let (mut up_tx, mut up_rx) = upstream.split();
    let (mut cl_tx, mut cl_rx) = socket.split();

    let to_upstream = async {
        while let Some(msg) = cl_rx.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(_) => break,
            };
            let Some(m) = into_tungstenite(msg) else {
                continue;
            };
            if up_tx.send(m).await.is_err() {
                break;
            }
        }
        let _ = up_tx.close().await;
    };

    let to_client = async {
        while let Some(msg) = up_rx.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(_) => break,
            };
            let Some(m) = into_axum(msg) else {
                continue;
            };
            if cl_tx.send(m).await.is_err() {
                break;
            }
        }
        let _ = cl_tx.close().await;
    };

    // When either direction ends the tunnel is finished.
    tokio::select! {
        _ = to_upstream => {},
        _ = to_client => {},
    }
}

fn into_tungstenite(
    msg: axum::extract::ws::Message,
) -> Option<tokio_tungstenite::tungstenite::Message> {
    use tokio_tungstenite::tungstenite::{protocol::CloseFrame, Message};
    Some(match msg {
        axum::extract::ws::Message::Text(t) => Message::Text(t),
        axum::extract::ws::Message::Binary(b) => Message::Binary(b),
        axum::extract::ws::Message::Ping(p) => Message::Ping(p),
        axum::extract::ws::Message::Pong(p) => Message::Pong(p),
        axum::extract::ws::Message::Close(c) => Message::Close(c.map(|f| CloseFrame {
            code: f.code.into(),
            reason: f.reason,
        })),
    })
}

fn into_axum(msg: tokio_tungstenite::tungstenite::Message) -> Option<axum::extract::ws::Message> {
    use axum::extract::ws::{CloseFrame, Message};
    Some(match msg {
        tokio_tungstenite::tungstenite::Message::Text(t) => Message::Text(t),
        tokio_tungstenite::tungstenite::Message::Binary(b) => Message::Binary(b),
        tokio_tungstenite::tungstenite::Message::Ping(p) => Message::Ping(p),
        tokio_tungstenite::tungstenite::Message::Pong(p) => Message::Pong(p),
        tokio_tungstenite::tungstenite::Message::Close(c) => {
            Message::Close(c.map(|f| CloseFrame {
                code: f.code.into(),
                reason: f.reason,
            }))
        }
        tokio_tungstenite::tungstenite::Message::Frame(_) => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::split_proxy_path;

    #[test]
    fn split_proxy_path_extracts_id_and_rest() {
        assert_eq!(
            split_proxy_path("/api/federation/nodes/abc/proxy/api/threads"),
            Some(("abc".to_string(), "api/threads".to_string()))
        );
        assert_eq!(
            split_proxy_path("/api/federation/nodes/abc/proxy"),
            Some(("abc".to_string(), String::new()))
        );
        assert_eq!(
            split_proxy_path("/api/federation/nodes/abc/proxy/"),
            Some(("abc".to_string(), String::new()))
        );
        assert_eq!(
            split_proxy_path("/api/federation/nodes/abc/proxied/x"),
            None
        );
        assert_eq!(split_proxy_path("/api/federation/nodes//proxy/x"), None);
        assert_eq!(split_proxy_path("/api/other"), None);
    }
}
