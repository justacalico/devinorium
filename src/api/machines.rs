//! Machine routes: the owner-managed list of machines an AI thread can
//! remote-control over VNC (screen) or SSH (shell).
//!
//! All routes are owner-only: referencing a machine mints a run-scoped
//! control grant, so even listing (the composer `@` picker's data source)
//! stays behind the owner boundary. Stored secrets — the VNC/SSH password
//! and the SSH private key — are never serialized: responses carry
//! `has_password`/`has_ssh_key` instead.

use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::machines::{MachineRow, MachineUpdate, KIND_SSH, KIND_VNC};
use crate::AppState;

const DEFAULT_VNC_PORT: i64 = 5900;
const DEFAULT_SSH_PORT: i64 = 22;
const MAX_NAME_LEN: usize = 128;
const MAX_HOST_LEN: usize = 255;
const MAX_USER_LEN: usize = 128;
const MAX_PASSWORD_LEN: usize = 256;
const MAX_SSH_KEY_LEN: usize = 32 * 1024;
/// Whole-probe budget; the per-read timeouts in the clients still apply.
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

/// Machine as the API reports it — no secrets.
#[derive(Debug, Serialize)]
pub struct MachineOut {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub host: String,
    pub port: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub ssh_user: String,
    /// Pinned host-key fingerprint (TOFU); not a secret.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub ssh_fingerprint: String,
    pub has_password: bool,
    pub has_ssh_key: bool,
    pub created_at: String,
    pub updated_at: String,
}

impl From<MachineRow> for MachineOut {
    fn from(m: MachineRow) -> Self {
        Self {
            id: m.id,
            name: m.name,
            kind: m.kind,
            host: m.host,
            port: m.port,
            ssh_user: m.ssh_user,
            ssh_fingerprint: m.ssh_fingerprint,
            has_password: !m.password.is_empty(),
            has_ssh_key: !m.ssh_key.is_empty(),
            created_at: m.created_at,
            updated_at: m.updated_at,
        }
    }
}

#[derive(Debug, Deserialize)]
struct CreateMachine {
    name: String,
    /// `vnc` or `ssh`; absent means VNC for back-compat with older clients.
    kind: Option<String>,
    host: String,
    port: Option<i64>,
    ssh_user: Option<String>,
    password: Option<String>,
    ssh_key: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UpdateMachine {
    name: Option<String>,
    kind: Option<String>,
    host: Option<String>,
    port: Option<i64>,
    ssh_user: Option<String>,
    /// Absent keeps the stored password; present replaces it (empty clears).
    password: Option<String>,
    /// Absent keeps the stored key; present replaces it (empty clears).
    ssh_key: Option<String>,
    /// Absent keeps the pinned host key; present replaces it (empty clears
    /// so the next connection re-pins). Set automatically when host or
    /// port changes.
    ssh_fingerprint: Option<String>,
}

fn bad_request(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(ApiError::new(msg))).into_response()
}

#[allow(clippy::result_large_err)]
fn clean_kind(raw: Option<&str>) -> Result<String, Response> {
    match raw.unwrap_or(KIND_VNC) {
        KIND_VNC => Ok(KIND_VNC.to_string()),
        KIND_SSH => Ok(KIND_SSH.to_string()),
        _ => Err(bad_request("kind must be vnc or ssh")),
    }
}

/// Normalize and validate the machine host: trims, strips a `vnc://`,
/// `ssh://`, or `tcp://` scheme the user may have pasted, and rejects
/// anything that cannot name a TCP endpoint. A `user@` prefix and a
/// `:port` suffix (`host:5901`, `host:22`, `[v6]:5901`) are split off and
/// returned separately — storing them in the host would produce the
/// unconnectable `host:port:port`. Hosts go into the provider prompt
/// verbatim, so the allowed charset is deliberately narrow (DNS names,
/// IPv4, bracketed IPv6 literals).
#[allow(clippy::result_large_err)]
fn clean_host(raw: &str) -> Result<(String, Option<i64>, Option<String>), Response> {
    let mut host = raw.trim();
    for scheme in ["vnc://", "ssh://", "tcp://", "rfb://"] {
        if let Some(rest) = host.strip_prefix(scheme) {
            host = rest.trim();
        }
    }
    // Drop a trailing path pasted as a URL.
    if let Some(idx) = host.find('/') {
        host = &host[..idx];
    }
    let mut host_user = None;
    if let Some((u, h)) = host.rsplit_once('@') {
        // `ssh://user:pass@host` — only the login name is kept; a pasted
        // password is dropped rather than stored in the user field.
        host_user = Some(u.split(':').next().unwrap_or(u).to_string());
        host = h;
    }
    let mut host_port = None;
    if host.contains(']') {
        // Bracketed IPv6: everything after `]` must be `:digits` or nothing.
        if let Some(idx) = host.find("]:") {
            let p = &host[idx + 2..];
            if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad_request("invalid host"));
            }
            host_port = Some(
                p.parse::<i64>()
                    .map_err(|_| bad_request("port must be between 1 and 65535"))?,
            );
            host = &host[..idx + 1];
        }
        if let Some(close) = host.find(']') {
            if close + 1 != host.len() {
                return Err(bad_request("invalid host"));
            }
        }
    } else if host.matches(':').count() == 1 {
        if let Some((h, p)) = host.split_once(':') {
            if p.is_empty() {
                return Err(bad_request("invalid host"));
            }
            if p.bytes().next().is_some_and(|b| b.is_ascii_digit()) {
                // A numeric-looking suffix must be a clean port.
                if !p.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(bad_request("invalid port"));
                }
                host_port = Some(
                    p.parse::<i64>()
                        .map_err(|_| bad_request("port must be between 1 and 65535"))?,
                );
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
        return Err(bad_request("invalid host"));
    }
    match host_port {
        Some(p) if !(1..=65535).contains(&p) => {
            Err(bad_request("port must be between 1 and 65535"))
        }
        _ => Ok((host.to_string(), host_port, host_user)),
    }
}

#[allow(clippy::result_large_err)]
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
        return Err(bad_request("invalid name"));
    }
    Ok(name.to_string())
}

#[allow(clippy::result_large_err)]
fn clean_port(port: Option<i64>, kind: &str) -> Result<i64, Response> {
    let default = if kind == KIND_SSH {
        DEFAULT_SSH_PORT
    } else {
        DEFAULT_VNC_PORT
    };
    match port.unwrap_or(default) {
        p if (1..=65535).contains(&p) => Ok(p),
        _ => Err(bad_request("port must be between 1 and 65535")),
    }
}

#[allow(clippy::result_large_err)]
fn clean_password(password: Option<String>) -> Result<Option<String>, Response> {
    match password {
        Some(p) if p.chars().count() > MAX_PASSWORD_LEN => Err(bad_request("password too long")),
        other => Ok(other),
    }
}

/// SSH usernames go into the provider prompt; keep the charset tight
/// (Unix/Windows login forms, `domain\\user`, `user@domain`). Mirrors the
/// secret-field convention: absent keeps the stored value, an empty string
/// clears it.
#[allow(clippy::result_large_err)]
fn clean_ssh_user(raw: Option<&str>) -> Result<Option<String>, Response> {
    let Some(raw) = raw else { return Ok(None) };
    let user = raw.trim();
    if user.is_empty() {
        return Ok(Some(String::new()));
    }
    let valid = user.chars().count() <= MAX_USER_LEN
        && !user.chars().any(|c| c.is_control() || c == '"' || c == '/')
        && user
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'@' | b'\\'));
    if !valid {
        return Err(bad_request("invalid ssh username"));
    }
    Ok(Some(user.to_string()))
}

/// Pinned host-key fingerprints are `SHA256:<base64>` strings; an empty
/// value clears the pin so the next connection re-learns the key.
#[allow(clippy::result_large_err)]
fn clean_ssh_fingerprint(raw: Option<String>) -> Result<Option<String>, Response> {
    match raw {
        Some(f) => {
            let f = f.trim().to_string();
            let valid = f.is_empty()
                || (f.len() <= 128
                    && f.strip_prefix("SHA256:").is_some_and(|b| {
                        !b.is_empty()
                            && b.bytes().all(|c| {
                                c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'=')
                            })
                    }));
            if !valid {
                return Err(bad_request("invalid ssh fingerprint"));
            }
            Ok(Some(f))
        }
        None => Ok(None),
    }
}

#[allow(clippy::result_large_err)]
fn clean_ssh_key(raw: Option<String>) -> Result<Option<String>, Response> {
    match raw {
        Some(k) => {
            let k = k.trim().to_string();
            if k.chars().count() > MAX_SSH_KEY_LEN {
                return Err(bad_request("ssh key too long"));
            }
            let looks_like_pem = k.contains("-----BEGIN") && k.contains("PRIVATE KEY-----");
            if !k.is_empty() && !looks_like_pem {
                return Err(bad_request("invalid ssh private key"));
            }
            Ok(Some(k))
        }
        None => Ok(None),
    }
}

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response()
}

fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    // Owner-only: the list exists to feed the `@` machine picker, and
    // referencing a machine mints a control grant — also owner-only.
    if !user.is_owner {
        return forbidden();
    }
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
    let kind = match clean_kind(req.kind.as_deref()) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let name = match clean_name(&req.name) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let (host, host_port, host_user) = match clean_host(&req.host) {
        Ok(v) => v,
        Err(r) => return r,
    };
    // A port embedded in the pasted URL is part of the endpoint the user
    // asked for, so it wins over the separate field; same for `user@`.
    let port = match clean_port(host_port.or(req.port), &kind) {
        Ok(v) => v,
        Err(r) => return r,
    };
    // `user@` in the pasted URL only applies to ssh entries.
    let user_field = if kind == KIND_SSH {
        host_user.as_deref().or(req.ssh_user.as_deref())
    } else {
        req.ssh_user.as_deref()
    };
    // SSH-only fields on a vnc entry would produce meaningless badges;
    // only an explicit empty clear is tolerated.
    let ssh_fields_set = [req.ssh_user.as_deref(), req.ssh_key.as_deref()]
        .into_iter()
        .flatten()
        .any(|v| !v.trim().is_empty());
    if kind != KIND_SSH && ssh_fields_set {
        return bad_request("ssh fields require kind ssh");
    }
    let ssh_user = match clean_ssh_user(user_field) {
        Ok(v) => v.unwrap_or_default(),
        Err(r) => return r,
    };
    if kind == KIND_SSH && ssh_user.is_empty() {
        return bad_request("ssh machines need a username");
    }
    let password = match clean_password(req.password) {
        Ok(v) => v.unwrap_or_default(),
        Err(r) => return r,
    };
    let ssh_key = match clean_ssh_key(req.ssh_key) {
        Ok(v) => v.unwrap_or_default(),
        Err(r) => return r,
    };

    match state
        .db
        .create_machine(&name, &kind, &host, port, &ssh_user, &password, &ssh_key)
        .await
    {
        Ok(m) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "machine.create",
                    &serde_json::json!({"machine_id": m.id, "name": m.name, "kind": m.kind, "host": m.host, "port": m.port}),
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
    let existing = match state.db.get_machine(id).await {
        Ok(Some(m)) => m,
        Ok(None) => return not_found(),
        Err(e) => return map_err_internal(e).into_response(),
    };
    #[allow(clippy::result_large_err)]
    let kind = match req.kind.as_deref().map(|k| clean_kind(Some(k))) {
        Some(Ok(v)) => Some(v),
        Some(Err(r)) => return r,
        None => None,
    };
    let name = match req.name.as_deref().map(clean_name) {
        Some(Ok(v)) => Some(v),
        Some(Err(r)) => return r,
        None => None,
    };
    let (host, host_port, host_user) = match req.host.as_deref().map(clean_host) {
        Some(Ok((h, p, u))) => (Some(h), p, u),
        Some(Err(r)) => return r,
        None => (None, None, None),
    };
    // As in create, a port embedded in a new host wins over `port`.
    let port = match host_port.or(req.port) {
        Some(p) => match clean_port(Some(p), kind.as_deref().unwrap_or(&existing.kind)) {
            Ok(v) => Some(v),
            Err(r) => return r,
        },
        None => None,
    };
    let merged_kind = kind.as_deref().unwrap_or(&existing.kind);
    // A scope flip with no explicit port follows the new default when the
    // stored port is just the old default (5900 -> 22 and back).
    let port = match (port, &kind) {
        (None, Some(new_kind)) if *new_kind != existing.kind => {
            let old_default = if existing.kind == KIND_SSH {
                DEFAULT_SSH_PORT
            } else {
                DEFAULT_VNC_PORT
            };
            if existing.port == old_default {
                match clean_port(None, new_kind) {
                    Ok(v) => Some(v),
                    Err(r) => return r,
                }
            } else {
                None
            }
        }
        (p, _) => p,
    };
    let user_field = if merged_kind == KIND_SSH {
        host_user.as_deref().or(req.ssh_user.as_deref())
    } else {
        req.ssh_user.as_deref()
    };
    // SSH-only fields on a vnc entry would produce meaningless badges;
    // only an explicit empty clear is tolerated.
    let ssh_fields_set = [
        req.ssh_user.as_deref(),
        req.ssh_key.as_deref(),
        req.ssh_fingerprint.as_deref(),
    ]
    .into_iter()
    .flatten()
    .any(|v| !v.trim().is_empty());
    if merged_kind != KIND_SSH && ssh_fields_set {
        return bad_request("ssh fields require kind ssh");
    }
    let ssh_user = match clean_ssh_user(user_field) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let merged_user = ssh_user.as_deref().unwrap_or(&existing.ssh_user);
    if merged_kind == KIND_SSH && merged_user.is_empty() {
        return bad_request("ssh machines need a username");
    }
    let password = match clean_password(req.password) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let ssh_key = match clean_ssh_key(req.ssh_key) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let ssh_fingerprint = match clean_ssh_fingerprint(req.ssh_fingerprint) {
        Ok(v) => v,
        Err(r) => return r,
    };
    // A moved endpoint cannot keep the old host key's pin: changing host
    // or port clears it unless the request says otherwise. Resending the
    // same values (the Flutter editor always does) is not a change.
    let moved = host.as_deref().is_some_and(|h| h != existing.host)
        || port.is_some_and(|p| p != existing.port);
    let ssh_fingerprint = match ssh_fingerprint {
        Some(_) => ssh_fingerprint,
        None if moved => Some(String::new()),
        None => None,
    };

    let patch = MachineUpdate {
        name,
        kind,
        host,
        port,
        ssh_user,
        ssh_fingerprint,
        password,
        ssh_key,
    };
    match state.db.update_machine(id, &patch).await {
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

/// Probe the machine. VNC runs the handshake and reports framebuffer
/// geometry plus the desktop name; SSH authenticates, runs a trivial
/// command, and reports the remote hostname. Errors never include the
/// stored secrets.
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
    let out = match machine.kind.as_str() {
        KIND_SSH => probe_ssh(&state, &machine, port).await,
        _ => probe_vnc(&machine, port).await,
    };
    if out.ok {
        let _ = state
            .db
            .audit(
                Some(user.id),
                "machine.test",
                &serde_json::json!({"machine_id": id}),
                None,
            )
            .await;
    }
    Json(out).into_response()
}

async fn probe_vnc(machine: &MachineRow, port: u16) -> MachineTestOut {
    let probe = tokio::time::timeout(
        PROBE_TIMEOUT,
        crate::vnc::VncClient::connect(&machine.host, port, &machine.password),
    )
    .await;
    match probe {
        Ok(Ok(client)) => MachineTestOut {
            ok: true,
            error: None,
            width: Some(client.info.width),
            height: Some(client.info.height),
            name: Some(client.info.name),
        },
        Ok(Err(e)) => MachineTestOut {
            ok: false,
            error: Some(format!("{e:#}")),
            width: None,
            height: None,
            name: None,
        },
        Err(_) => MachineTestOut {
            ok: false,
            error: Some("vnc probe timed out".to_string()),
            width: None,
            height: None,
            name: None,
        },
    }
}

async fn probe_ssh(state: &AppState, machine: &MachineRow, port: u16) -> MachineTestOut {
    let probe = tokio::time::timeout(PROBE_TIMEOUT, async {
        let mut session = crate::ssh::SshSession::connect(
            &machine.host,
            port,
            &machine.ssh_user,
            &machine.password,
            &machine.ssh_key,
            &machine.ssh_fingerprint,
        )
        .await?;
        // Trust-on-first-use: pin the host key seen on this probe so later
        // connections reject a different server.
        if machine.ssh_fingerprint.is_empty() && !session.fingerprint.is_empty() {
            if let Err(e) = state
                .db
                .pin_machine_fingerprint(machine.id, &session.fingerprint)
                .await
            {
                tracing::warn!(machine_id = machine.id, "failed to pin ssh host key: {e}");
            }
        }
        // `hostname` exists on cmd.exe, PowerShell, and every shell —
        // the one probe that works across SSH targets.
        let out = session.exec("hostname").await?;
        session.disconnect().await;
        anyhow::Ok(out)
    })
    .await;
    let name_fallback = format!("{}@{}", machine.ssh_user, machine.host);
    match probe {
        Ok(Ok(out)) => {
            let reported = String::from_utf8_lossy(&out.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            MachineTestOut {
                ok: true,
                error: None,
                width: None,
                height: None,
                name: Some(if reported.is_empty() {
                    name_fallback
                } else {
                    reported
                }),
            }
        }
        Ok(Err(e)) => MachineTestOut {
            ok: false,
            error: Some(format!("{e:#}")),
            width: None,
            height: None,
            name: None,
        },
        Err(_) => MachineTestOut {
            ok: false,
            error: Some("ssh probe timed out".to_string()),
            width: None,
            height: None,
            name: None,
        },
    }
}
