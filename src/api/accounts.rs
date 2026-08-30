//! Owner-managed user account routes.
//!
//! Only users with `is_owner = true` can list, create, or disable accounts.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::{map_err_internal, ApiError};
use crate::auth::{password, session::CurrentUser};
use crate::db::{NewUser, UserRow};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/users", get(list).post(create))
        .route("/api/users/:id", patch(update))
}

#[derive(Debug, Serialize)]
pub struct UserOut {
    pub id: i64,
    pub username: String,
    pub role: String,
    pub is_owner: bool,
    pub disabled: bool,
    pub totp_enabled: bool,
    pub created_at: String,
}

impl From<UserRow> for UserOut {
    fn from(u: UserRow) -> Self {
        Self {
            id: u.id,
            username: u.username,
            role: u.role,
            is_owner: u.is_owner,
            disabled: u.disabled,
            totp_enabled: u.totp_enabled,
            created_at: u.created_at,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateUserRequest {
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateUserResponse {
    pub ok: bool,
    pub id: i64,
    pub username: String,
}

#[derive(Debug, Deserialize)]
pub struct UpdateUserRequest {
    pub disabled: bool,
}

fn is_valid_username(s: &str) -> bool {
    let len = s.chars().count();
    if !(3..=32).contains(&len) {
        return false;
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
}

fn is_valid_password(s: &str) -> bool {
    let len = s.chars().count();
    (12..=1024).contains(&len)
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    match state.db.list_users().await {
        Ok(rows) => Json(rows.into_iter().map(UserOut::from).collect::<Vec<_>>()).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateUserRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    let username = match req.username.as_deref().filter(|s| !s.is_empty()) {
        Some(u) => u,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("username is required")),
            )
                .into_response()
        }
    };
    let password = match req.password.as_deref().filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("password is required")),
            )
                .into_response()
        }
    };

    if !is_valid_username(username) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new(
                "username must be 3-32 characters and contain only alphanumeric, _, -, or .",
            )),
        )
            .into_response();
    }
    if !is_valid_password(password) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("password must be 12-1024 characters")),
        )
            .into_response();
    }

    if let Ok(Some(_)) = state.db.get_user_by_username(username).await {
        return (
            StatusCode::CONFLICT,
            Json(ApiError::new("username already taken")),
        )
            .into_response();
    }

    let hash = match password::hash(password) {
        Ok(h) => h,
        Err(e) => return map_err_internal(e).into_response(),
    };

    match state
        .db
        .create_user(NewUser {
            username: username.to_string(),
            password_hash: hash,
            is_owner: false,
        })
        .await
    {
        Ok(u) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "user.create",
                    &serde_json::json!({"created_user_id": u.id, "username": u.username}),
                    None,
                )
                .await;
            (
                StatusCode::CREATED,
                Json(CreateUserResponse {
                    ok: true,
                    id: u.id,
                    username: u.username,
                }),
            )
                .into_response()
        }
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn update(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<UpdateUserRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    let target = match state.db.get_user_by_id(id).await {
        Ok(Some(u)) => u,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("user not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    if target.is_owner {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("cannot disable an owner account")),
        )
            .into_response();
    }

    if let Err(e) = state.db.set_user_disabled(id, req.disabled).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            if req.disabled {
                "user.disable"
            } else {
                "user.enable"
            },
            &serde_json::json!({"target_user_id": id}),
            None,
        )
        .await;

    Json(serde_json::json!({ "ok": true })).into_response()
}
