//! Invite token API routes.
//!
//! Any authenticated user (the only role is `user`) can create invite tokens
//! to bring in new users. Tokens are single-use and expire.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::Serialize;

use crate::auth::session::CurrentUser;
use crate::db::invites::InviteRow;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/invites", get(list).post(create))
}

#[derive(Debug, Serialize)]
pub struct InviteOut {
    pub token: String,
    pub created_by_user_id: i64,
    pub created_at: String,
    pub used_by_user_id: Option<i64>,
    pub used_at: Option<String>,
    pub expires_at: String,
}

impl From<InviteRow> for InviteOut {
    fn from(i: InviteRow) -> Self {
        Self {
            token: i.token,
            created_by_user_id: i.created_by_user_id,
            created_at: i.created_at,
            used_by_user_id: i.used_by_user_id,
            used_at: i.used_at,
            expires_at: i.expires_at,
        }
    }
}

async fn list(State(state): State<AppState>, CurrentUser(_user): CurrentUser) -> Response {
    match state.db.list_invites().await {
        Ok(rows) => Json(rows.into_iter().map(InviteOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn create(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.create_invite(user.id, 7).await {
        Ok(token) => {
            let _ = state
                .db
                .audit(Some(user.id), "invite.create", &serde_json::json!({}), None)
                .await;
            (
                StatusCode::CREATED,
                Json(serde_json::json!({"token": token})),
            )
                .into_response()
        }
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}
