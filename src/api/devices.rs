//! Pairing and device management routes.
//!
//! A "device" is a server-side session. Native clients authenticate by
//! importing a pairing file downloaded from the web UI, which contains a
//! session token. Users can list and revoke their own devices.

use axum::extract::{Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::{extract_token, CurrentUser};
use crate::db::SessionRow;
use crate::api::{map_err_internal, ApiError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/pairing", post(create_pairing))
        .route("/api/auth/devices", get(list_devices))
        .route("/api/auth/devices/revoke", post(revoke_device))
}

const DEFAULT_PAIRING_NAME: &str = "Paired device";
const MAX_PAIRING_NAME_LEN: usize = 100;
const MAX_DEVICES_PER_USER: i64 = 10;

#[derive(Debug, Deserialize)]
pub struct CreatePairingRequest {
    pub server_url: String,
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PairingResponse {
    pub ok: bool,
    pub token: String,
    pub device_id: String,
    pub username: String,
    pub server_url: String,
}

#[derive(Debug, Deserialize)]
pub struct RevokeDeviceRequest {
    pub device_id: String,
}

#[derive(Debug, Serialize)]
pub struct DeviceOut {
    pub device_id: String,
    pub token_prefix: String,
    pub name: Option<String>,
    pub created_at: String,
    pub last_seen_at: String,
    pub expires_at: String,
    pub is_current: bool,
}

impl DeviceOut {
    fn from_row(row: SessionRow, current_token: &str) -> Self {
        let prefix_len = 8.min(row.token.len());
        Self {
            device_id: row.device_id,
            token_prefix: row.token[..prefix_len].to_string(),
            name: row.name,
            created_at: row.created_at,
            last_seen_at: row.last_seen_at,
            expires_at: row.expires_at,
            is_current: row.token == current_token,
        }
    }
}

fn bad_request(msg: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ApiError::new(msg)),
    )
        .into_response()
}

fn parse_origin(uri_str: &str) -> Option<String> {
    let uri = uri_str.parse::<axum::http::Uri>().ok()?;
    let scheme = uri.scheme_str()?;
    let authority = uri.authority()?;
    Some(format!("{}://{}", scheme, authority))
}

fn request_origin(headers: &HeaderMap) -> Option<String> {
    if let Some(origin) = headers.get(header::ORIGIN) {
        if let Ok(s) = origin.to_str() {
            return parse_origin(s).or(Some(s.to_string()));
        }
    }
    if let Some(referer) = headers.get(header::REFERER) {
        if let Ok(s) = referer.to_str() {
            return parse_origin(s);
        }
    }
    None
}

fn validate_pairing_name(name: &str) -> Result<&str, &'static str> {
    if name.chars().count() > MAX_PAIRING_NAME_LEN {
        return Err("name must be at most 100 characters");
    }
    if name.chars().any(|c| c.is_control()) {
        return Err("name contains invalid characters");
    }
    Ok(name)
}

async fn create_pairing(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    headers: HeaderMap,
    Json(body): Json<CreatePairingRequest>,
) -> Response {
    let server_url = body.server_url.trim();
    if server_url.is_empty() {
        return bad_request("server_url is required");
    }

    let server_origin = match parse_origin(server_url) {
        Some(o) => o,
        None => return bad_request("server_url must be a valid http:// or https:// URL"),
    };

    if !server_origin.starts_with("http://") && !server_origin.starts_with("https://") {
        return bad_request("server_url must start with http:// or https://");
    }

    match request_origin(&headers) {
        Some(origin) => {
            if server_origin != origin {
                return bad_request("server_url does not match the request origin");
            }
        }
        None => {
            return bad_request("missing origin or referer header");
        }
    }

    let name = body
        .name
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or(DEFAULT_PAIRING_NAME);

    if let Err(msg) = validate_pairing_name(name) {
        return bad_request(msg);
    }

    let sess = match state
        .db
        .create_session_limited(user.id, 30, None, Some(name), MAX_DEVICES_PER_USER)
        .await
    {
        Ok(s) => s,
        Err(e) if e.to_string().contains("too many paired devices") => {
            return bad_request("too many paired devices");
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    let _ = state
        .db
        .audit(
            Some(user.id),
            "pairing.create",
            &serde_json::json!({
                "device_id": &sess.device_id,
                "token_prefix": &sess.token[..8.min(sess.token.len())]
            }),
            None,
        )
        .await;

    Json(PairingResponse {
        ok: true,
        token: sess.token,
        device_id: sess.device_id,
        username: user.username,
        server_url: server_origin,
    })
    .into_response()
}

async fn list_devices(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    req: Request,
) -> Response {
    let current_token = extract_token(&req).unwrap_or_default();
    match state.db.list_user_sessions(user.id).await {
        Ok(rows) => Json(
            rows.into_iter()
                .map(|r| DeviceOut::from_row(r, &current_token))
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn revoke_device(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<RevokeDeviceRequest>,
) -> Response {
    if req.device_id.is_empty() {
        return bad_request("device_id is required");
    }

    match state.db.delete_session_by_device_id_for_user(&req.device_id, user.id).await {
        Ok(true) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "device.revoke",
                    &serde_json::json!({ "device_id": &req.device_id }),
                    None,
                )
                .await;
            Json(serde_json::json!({ "ok": true })).into_response()
        }
        Ok(false) => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("device not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}
