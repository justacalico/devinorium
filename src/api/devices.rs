//! Pairing and device management routes.
//!
//! A "device" is a server-side session. Native clients authenticate by
//! importing a pairing file downloaded from the web UI, which contains a
//! session token. Users can list and revoke their own devices.

use axum::extract::{Request, State};
use axum::http::StatusCode;
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

#[derive(Debug, Deserialize)]
pub struct CreatePairingRequest {
    pub server_url: String,
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PairingResponse {
    pub ok: bool,
    pub token: String,
    pub username: String,
    pub server_url: String,
}

#[derive(Debug, Deserialize)]
pub struct RevokeDeviceRequest {
    pub token: String,
}

#[derive(Debug, Serialize)]
pub struct DeviceOut {
    pub token: String,
    pub name: Option<String>,
    pub created_at: String,
    pub last_seen_at: String,
    pub expires_at: String,
    pub is_current: bool,
}

impl DeviceOut {
    fn from_row(row: SessionRow, current_token: &str) -> Self {
        Self {
            token: row.token.clone(),
            name: row.name,
            created_at: row.created_at,
            last_seen_at: row.last_seen_at,
            expires_at: row.expires_at,
            is_current: row.token == current_token,
        }
    }
}

async fn create_pairing(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreatePairingRequest>,
) -> Response {
    let server_url = req.server_url.trim();
    if server_url.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("server_url is required")),
        )
            .into_response();
    }
    if !(server_url.starts_with("http://") || server_url.starts_with("https://")) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("server_url must start with http:// or https://")),
        )
            .into_response();
    }

    let name = req
        .name
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or(DEFAULT_PAIRING_NAME);

    let sess = match state.db.create_session(user.id, 30, None, Some(name)).await {
        Ok(s) => s,
        Err(e) => return map_err_internal(e).into_response(),
    };

    let _ = state
        .db
        .audit(
            Some(user.id),
            "pairing.create",
            &serde_json::json!({"token_prefix": &sess.token[..8.min(sess.token.len())]}),
            None,
        )
        .await;

    Json(PairingResponse {
        ok: true,
        token: sess.token,
        username: user.username,
        server_url: server_url.to_string(),
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
    if req.token.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("token is required")),
        )
            .into_response();
    }

    match state.db.delete_session_for_user(&req.token, user.id).await {
        Ok(true) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "device.revoke",
                    &serde_json::json!({"token_prefix": &req.token[..8.min(req.token.len())]}),
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
