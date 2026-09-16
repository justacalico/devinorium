//! Machine routes: the owner-managed list of VNC machines an AI thread can
//! remote-control.
//!
//! Any signed-in user can list machines — the composer needs them for `@`
//! references — but only the owner can create, update, delete, or probe
//! them. The stored VNC password is never serialized: responses carry
//! `has_password` instead.

use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::machines::MachineRow;
use crate::AppState;

const DEFAULT_VNC_PORT: i64 = 5900;
const MAX_NAME_LEN: usize = 128;
const MAX_HOST_LEN: usize = 255;
const MAX_PASSWORD_LEN: usize = 256;
/// Whole-probe budget; the per-read timeouts in the client still apply.
const PROBE_TIMEOUT: Duration = Duration::from_secs(60);

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/machines", get(list).post(create))
        .route(
            "/api/machines/:id",
            axum::routing::patch(update).delete(remove),
        )
        .route("/api/machines/:id/test", post(test_connection))
}

/// Machine as the API reports it — no password.
#[derive(Debug, Serialize)]
pub struct MachineOut {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub port: i64,
    pub has_password: bool,
    pub created_at: String,
    pub updated_at: String,
}

impl From<MachineRow> for MachineOut {
    fn from(m: MachineRow) -> Self {
        Self {
            id: m.id,
            name: m.name,
            host: m.host,
            port: m.port,
            has_password: !m.password.is_empty(),
            created_at: m.created_at,
            updated_at: m.updated_at,
        }
    }
}

#[derive(Debug, Deserialize)]
struct CreateMachine {
    name: String,
    host: String,
    port: Option<i64>,
    password: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UpdateMachine {
    name: Option<String>,
    host: Option<String>,
    port: Option<i64>,
    /// Absent keeps the stored password; present replaces it (empty clears).
    password: Option<String>,
}

/// Normalize and validate the machine host: trims, strips a `vnc://` or
/// `tcp://` scheme the user may have pasted, and rejects anything that
/// cannot name a TCP endpoint. A `:port` suffix (`host:5901` or
/// `[v6]:5901`) is split off and returned separately — storing it in the
/// host would produce the unconnectable `host:port:port`. Hosts go into
/// the provider prompt verbatim, so the allowed charset is deliberately
/// narrow (DNS names, IPv4, bracketed IPv6 literals).
fn clean_host(raw: &str) -> Result<(String, Option<i64>), Response> {
    let mut host = raw.trim();
    for scheme in ["vnc://", "tcp://", "rfb://"] {
        if let Some(rest) = host.strip_prefix(scheme) {
            host = rest.trim();
        }
    }
    // Drop a trailing path pasted as a URL.
    if let Some(idx) = host.find('/') {
        host = &host[..idx];
    }
    let mut host_port = None;
    if let Some(idx) = host.find("]:") {
        // Bracketed IPv6 with a port: keep the closing bracket on the host.
        let p = &host[idx + 2..];
        if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) {
            host_port = p.parse::<i64>().ok();
            host = &host[..idx + 1];
        }
    } else if host.matches(':').count() == 1 {
        if let Some((h, p)) = host.split_once(':') {
            if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) {
                host_port = p.parse::<i64>().ok();
                host = h;
            }
        }
    }
    let valid = !host.is_empty()
        && host.chars().count() <= MAX_HOST_LEN
        && !host.contains("://")
        && host.bytes().all(|b| {
            b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b':' | b'[' | b']' | b'%')
        });
    if !valid {
        return Err((StatusCode::BAD_REQUEST, Json(ApiError::new("invalid host"))).into_response());
    }
    match host_port {
        Some(p) if !(1..=65535).contains(&p) => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("port must be between 1 and 65535")),
        )
            .into_response()),
        _ => Ok((host.to_string(), host_port)),
    }
}

fn clean_name(raw: &str) -> Result<String, Response> {
    let name = raw.trim();
    // Names are quoted inside the provider prompt, so control characters
    // and quote/backslash would let a name reshape the prompt block.
    if name.is_empty()
        || name.chars().count() > MAX_NAME_LEN
        || name
            .chars()
            .any(|c| c.is_control() || c == '"' || c == '\\')
    {
        return Err((StatusCode::BAD_REQUEST, Json(ApiError::new("invalid name"))).into_response());
    }
    Ok(name.to_string())
}

fn clean_port(port: Option<i64>) -> Result<i64, Response> {
    match port.unwrap_or(DEFAULT_VNC_PORT) {
        p if (1..=65535).contains(&p) => Ok(p),
        _ => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("port must be between 1 and 65535")),
        )
            .into_response()),
    }
}

fn clean_password(password: Option<String>) -> Result<Option<String>, Response> {
    match password {
        Some(p) if p.chars().count() > MAX_PASSWORD_LEN => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("password too long")),
        )
            .into_response()),
        other => Ok(other),
    }
}

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response()
}

fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
}

async fn list(State(state): State<AppState>, CurrentUser(_user): CurrentUser) -> Response {
    match state.db.list_machines().await {
        Ok(machines) => Json(
            machines
                .into_iter()
                .map(MachineOut::from)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateMachine>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    let name = match clean_name(&req.name) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (host, host_port) = match clean_host(&req.host) {
        Ok(v) => v,
        Err(r) => return r,
    };
    // A port embedded in the pasted URL is part of the endpoint the user
    // asked for, so it wins over the separate field.
    let port = match clean_port(host_port.or(req.port)) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let password = match clean_password(req.password) {
        Ok(v) => v.unwrap_or_default(),
        Err(r) => return r,
    };

    match state.db.create_machine(&name, &host, port, &password).await {
        Ok(m) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "machine.create",
                    &serde_json::json!({"machine_id": m.id, "name": m.name, "host": m.host, "port": m.port}),
                    None,
                )
                .await;
            (StatusCode::CREATED, Json(MachineOut::from(m))).into_response()
        }
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn update(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<UpdateMachine>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    let name = match req.name.as_deref().map(clean_name) {
        Some(Ok(v)) => Some(v),
        Some(Err(r)) => return r,
        None => None,
    };
    let (host, host_port) = match req.host.as_deref().map(clean_host) {
        Some(Ok((h, p))) => (Some(h), p),
        Some(Err(r)) => return r,
        None => (None, None),
    };
    // As in create, a port embedded in a new host wins over `port`.
    let port = match host_port.or(req.port).map(|p| clean_port(Some(p))) {
        Some(Ok(v)) => Some(v),
        Some(Err(r)) => return r,
        None => None,
    };
    let password = match clean_password(req.password) {
        Ok(v) => v,
        Err(r) => return r,
    };

    match state
        .db
        .update_machine(
            id,
            name.as_deref(),
            host.as_deref(),
            port,
            password.as_deref(),
        )
        .await
    {
        Ok(Some(m)) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "machine.update",
                    &serde_json::json!({"machine_id": id, "name": m.name}),
                    None,
                )
                .await;
            Json(MachineOut::from(m)).into_response()
        }
        Ok(None) => not_found(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn remove(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    match state.db.delete_machine(id).await {
        Ok(true) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "machine.delete",
                    &serde_json::json!({"machine_id": id}),
                    None,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(false) => not_found(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Serialize)]
struct MachineTestOut {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    height: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

/// Probe the machine's VNC handshake. Reports framebuffer geometry and the
/// desktop name on success; the error string on failure.
async fn test_connection(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    let machine = match state.db.get_machine(id).await {
        Ok(Some(m)) => m,
        Ok(None) => return not_found(),
        Err(e) => return map_err_internal(e).into_response(),
    };
    let port = match u16::try_from(machine.port) {
        Ok(p) => p,
        Err(_) => return map_err_internal(anyhow::anyhow!("invalid stored port")).into_response(),
    };
    let probe = tokio::time::timeout(
        PROBE_TIMEOUT,
        crate::vnc::VncClient::connect(&machine.host, port, &machine.password),
    )
    .await;
    match probe {
        Ok(Ok(client)) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "machine.test",
                    &serde_json::json!({"machine_id": id}),
                    None,
                )
                .await;
            Json(MachineTestOut {
                ok: true,
                error: None,
                width: Some(client.info.width),
                height: Some(client.info.height),
                name: Some(client.info.name),
            })
            .into_response()
        }
        Ok(Err(e)) => Json(MachineTestOut {
            ok: false,
            error: Some(format!("{e:#}")),
            width: None,
            height: None,
            name: None,
        })
        .into_response(),
        Err(_) => Json(MachineTestOut {
            ok: false,
            error: Some("vnc probe timed out".to_string()),
            width: None,
            height: None,
            name: None,
        })
        .into_response(),
    }
}
