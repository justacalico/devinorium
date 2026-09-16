//! Machine-control endpoints for agents running on this host.
//!
//! These routes sit on the public router: callers authenticate with the
//! per-run capability token minted when a send references machines
//! (`Authorization: Bearer mc_...`), not a session. A token only covers the
//! machines the user referenced, so an agent can never reach a machine the
//! user did not hand it. The VNC password stays server-side — the agent
//! only ever sees the token.

use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::header::HeaderValue;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::Deserialize;

use crate::api::{map_err_internal, ApiError};
use crate::machine_grants::GrantInfo;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/api/machine-control/:machine_id/screenshot",
            get(screenshot),
        )
        .route("/api/machine-control/:machine_id/input", post(input))
}

/// Whole-request budget for one control call: handshake plus the operation.
/// The per-read/write timeouts inside the VNC client still apply; this caps
/// the total so a slow-drip server cannot pin a handler forever.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(60);

/// Resolve the bearer token to its grant, then check machine coverage.
/// `Err` is the response to return.
fn authorize(
    state: &AppState,
    headers: &axum::http::HeaderMap,
    machine_id: i64,
) -> Result<GrantInfo, Response> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.trim().strip_prefix("Bearer "))
        .unwrap_or("");
    match state.machine_grants.lookup(token) {
        None => Err((
            StatusCode::UNAUTHORIZED,
            Json(ApiError::new("invalid machine token")),
        )
            .into_response()),
        Some(grant) if !grant.machine_ids.contains(&machine_id) => Err((
            StatusCode::FORBIDDEN,
            Json(ApiError::new("token does not cover this machine")),
        )
            .into_response()),
        Some(grant) => Ok(grant),
    }
}

async fn screenshot(
    State(state): State<AppState>,
    Path(machine_id): Path<i64>,
    headers: axum::http::HeaderMap,
) -> Response {
    let grant = match authorize(&state, &headers, machine_id) {
        Ok(g) => g,
        Err(r) => return r,
    };
    let machine = match state.db.get_machine(machine_id).await {
        Ok(Some(m)) => m,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    let port = match u16::try_from(machine.port) {
        Ok(p) => p,
        Err(_) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(ApiError::new("invalid stored port")),
            )
                .into_response()
        }
    };
    let outcome = tokio::time::timeout(CONTROL_TIMEOUT, async {
        let mut client =
            crate::vnc::VncClient::connect(&machine.host, port, &machine.password).await?;
        client.screenshot().await
    })
    .await;
    match outcome {
        Ok(Ok(png)) => {
            let _ = state
                .db
                .audit(
                    Some(grant.user_id),
                    "machine.screenshot",
                    &serde_json::json!({"machine_id": machine_id}),
                    None,
                )
                .await;
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, HeaderValue::from_static("image/png"))],
                png,
            )
                .into_response()
        }
        Ok(Err(e)) => (
            StatusCode::BAD_GATEWAY,
            Json(ApiError::new(format!("vnc request failed: {e:#}"))),
        )
            .into_response(),
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(ApiError::new("vnc request timed out")),
        )
            .into_response(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind")]
enum MachineInput {
    /// Move the pointer without pressing anything.
    #[serde(rename = "move")]
    Move { x: i64, y: i64 },
    /// Move to (x, y) and press+release a button.
    #[serde(rename = "click")]
    Click {
        x: i64,
        y: i64,
        button: Option<String>,
    },
    /// Press a key or chord: "a", "Return", "ctrl+c", "ctrl+alt+del".
    #[serde(rename = "key")]
    Key { key: String },
    /// Type a string one character at a time.
    #[serde(rename = "type")]
    Type { text: String },
    /// Scroll at (x, y); `dy` > 0 scrolls up, < 0 scrolls down, |dy| clicks.
    #[serde(rename = "scroll")]
    Scroll { x: i64, y: i64, dy: i64 },
}

fn button_mask(button: Option<&str>) -> Result<u8, Response> {
    match button.unwrap_or("left") {
        "left" => Ok(1),
        "middle" => Ok(2),
        "right" => Ok(4),
        "scroll_up" | "wheel_up" => Ok(8),
        "scroll_down" | "wheel_down" => Ok(16),
        other => Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new(format!("unknown button {other:?}"))),
        )
            .into_response()),
    }
}

/// Valid pointer coords are `0..max`; `max` itself is off-screen.
fn coord(v: i64, max: u16) -> Result<u16, Response> {
    u16::try_from(v).ok().filter(|v| *v < max).ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("coordinate out of range")),
        )
            .into_response()
    })
}

const MAX_TYPE_LEN: usize = 64 * 1024;
const MAX_SCROLL_CLICKS: i64 = 100;
const MAX_KEY_LEN: usize = 64;

fn bad_request(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(ApiError::new(msg))).into_response()
}

/// Check every field that does not need framebuffer geometry. Runs before
/// the VNC connection so a rejected input never touches the remote host.
fn validate_input(req: &MachineInput) -> Result<(), Response> {
    match req {
        MachineInput::Click { button, .. } => button_mask(button.as_deref()).map(|_| ()),
        MachineInput::Key { key } => {
            if key.chars().count() > MAX_KEY_LEN {
                return Err(bad_request("key too long"));
            }
            if crate::vnc::key_chord(key).is_none() {
                return Err(bad_request("unknown key"));
            }
            Ok(())
        }
        MachineInput::Type { text } => {
            if text.chars().count() > MAX_TYPE_LEN {
                return Err(bad_request("text too long"));
            }
            Ok(())
        }
        MachineInput::Scroll { dy, .. } if *dy == 0 => Err(bad_request("dy must be non-zero")),
        _ => Ok(()),
    }
}

/// Pointer target for move/click/scroll, checked against the framebuffer.
fn pointer_target(
    req: &MachineInput,
    client: &crate::vnc::VncClient,
) -> Result<Option<(u16, u16)>, Response> {
    let (x, y) = match req {
        MachineInput::Move { x, y }
        | MachineInput::Click { x, y, .. }
        | MachineInput::Scroll { x, y, .. } => (*x, *y),
        _ => return Ok(None),
    };
    Ok(Some((
        coord(x, client.info.width)?,
        coord(y, client.info.height)?,
    )))
}

async fn run_input(
    client: &mut crate::vnc::VncClient,
    req: MachineInput,
    target: Option<(u16, u16)>,
) -> anyhow::Result<()> {
    match req {
        MachineInput::Move { .. } => {
            let (x, y) = target.unwrap_or((0, 0));
            client.pointer_event(x, y, 0).await?;
        }
        MachineInput::Click { button, .. } => {
            let (x, y) = target.unwrap_or((0, 0));
            // Validated by validate_input before the connection opened.
            let mask = button_mask(button.as_deref()).unwrap_or(1);
            client.pointer_event(x, y, 0).await?;
            client.pointer_event(x, y, mask).await?;
            client.pointer_event(x, y, 0).await?;
        }
        MachineInput::Key { key } => {
            client.press_chord(&key).await?;
        }
        MachineInput::Type { text } => {
            client.type_text(&text).await?;
        }
        MachineInput::Scroll { dy, .. } => {
            let (x, y) = target.unwrap_or((0, 0));
            let mask = if dy > 0 { 8 } else { 16 };
            let clicks = dy.saturating_abs().clamp(1, MAX_SCROLL_CLICKS);
            client.pointer_event(x, y, 0).await?;
            for _ in 0..clicks {
                client.pointer_event(x, y, mask).await?;
                client.pointer_event(x, y, 0).await?;
            }
        }
    }
    Ok(())
}

async fn input(
    State(state): State<AppState>,
    Path(machine_id): Path<i64>,
    headers: axum::http::HeaderMap,
    Json(req): Json<MachineInput>,
) -> Response {
    let grant = match authorize(&state, &headers, machine_id) {
        Ok(g) => g,
        Err(r) => return r,
    };
    if let Err(r) = validate_input(&req) {
        return r;
    }
    let machine = match state.db.get_machine(machine_id).await {
        Ok(Some(m)) => m,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    let port = match u16::try_from(machine.port) {
        Ok(p) => p,
        Err(_) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(ApiError::new("invalid stored port")),
            )
                .into_response()
        }
    };

    let kind = match &req {
        MachineInput::Move { .. } => "move",
        MachineInput::Click { .. } => "click",
        MachineInput::Key { .. } => "key",
        MachineInput::Type { .. } => "type",
        MachineInput::Scroll { .. } => "scroll",
    };

    // One deadline across connect + input; coordinate checks sit between
    // them because they need the framebuffer geometry from the handshake.
    let deadline = tokio::time::Instant::now() + CONTROL_TIMEOUT;
    let mut client = match tokio::time::timeout_at(
        deadline,
        crate::vnc::VncClient::connect(&machine.host, port, &machine.password),
    )
    .await
    {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => {
            return (
                StatusCode::BAD_GATEWAY,
                Json(ApiError::new(format!("vnc connect failed: {e:#}"))),
            )
                .into_response()
        }
        Err(_) => {
            return (
                StatusCode::GATEWAY_TIMEOUT,
                Json(ApiError::new("vnc request timed out")),
            )
                .into_response()
        }
    };
    let target = match pointer_target(&req, &client) {
        Ok(t) => t,
        Err(r) => return r,
    };

    match tokio::time::timeout_at(deadline, run_input(&mut client, req, target)).await {
        Ok(Ok(())) => {
            let _ = state
                .db
                .audit(
                    Some(grant.user_id),
                    "machine.input",
                    &serde_json::json!({"machine_id": machine_id, "kind": kind}),
                    None,
                )
                .await;
            Json(serde_json::json!({"ok": true})).into_response()
        }
        Ok(Err(e)) => (
            StatusCode::BAD_GATEWAY,
            Json(ApiError::new(format!("vnc request failed: {e:#}"))),
        )
            .into_response(),
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(ApiError::new("vnc request timed out")),
        )
            .into_response(),
    }
}
