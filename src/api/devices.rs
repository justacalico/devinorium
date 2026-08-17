//! Device (session) management routes.
//!
//! Users can list and revoke their own active server sessions.

use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::Serialize;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::{extract_token, CurrentUser};
use crate::db::SessionRow;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/devices", get(list_devices))
        .route("/api/auth/devices/revoke", post(revoke_device))
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

#[derive(Debug, serde::Deserialize)]
pub struct RevokeDeviceRequest {
    pub device_id: String,
}

async fn revoke_device(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<RevokeDeviceRequest>,
) -> Response {
    if req.device_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("device_id is required")),
        )
            .into_response();
    }

    match state
        .db
        .delete_session_by_device_id_for_user(&req.device_id, user.id)
        .await
    {
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
