//! Audit log API.
//!
//! `GET /api/audit` lists the security-relevant actions recorded by the
//! server, newest first. Owner-only: entries name other users and carry IP
//! hashes, so regular accounts must not see them.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::Serialize;

use crate::api::pagination::Pagination;
use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::audit::AuditRow;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/audit", get(list))
}

#[derive(Debug, Serialize)]
struct AuditEntryOut {
    id: i64,
    user_id: Option<i64>,
    username: Option<String>,
    action: String,
    /// The stored detail column holds a JSON string; it is emitted parsed so
    /// clients get an object instead of an escaped string.
    detail: serde_json::Value,
    ip_hash: Option<String>,
    created_at: String,
}

impl From<AuditRow> for AuditEntryOut {
    fn from(r: AuditRow) -> Self {
        Self {
            id: r.id,
            user_id: r.user_id,
            username: r.username,
            action: r.action,
            detail: serde_json::from_str(&r.detail).unwrap_or(serde_json::Value::String(r.detail)),
            ip_hash: r.ip_hash,
            created_at: r.created_at,
        }
    }
}

async fn list(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(page): Query<Pagination>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    let (limit, offset) = page.bounds();
    match state.db.list_audit(limit, offset).await {
        Ok(rows) => Json(
            rows.into_iter()
                .map(AuditEntryOut::from)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}
