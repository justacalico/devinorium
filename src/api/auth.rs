//! Authentication API routes: login, logout, register (invite-only),
//! TOTP setup/verify/disable, and `me`.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::{self, password, session::CurrentUser, totp};
use crate::db::NewUser;
use crate::AppState;

/// Public (unauthenticated) auth routes.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/login", post(login))
        .route("/api/auth/logout", post(logout))
        .route("/api/auth/register", post(register))
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub username: Option<String>,
    pub password: Option<String>,
    #[serde(default)]
    pub totp: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct LoginResponse {
    pub ok: bool,
    #[serde(default)]
    pub totp_required: bool,
    pub username: String,
}

async fn login(State(state): State<AppState>, Json(req): Json<LoginRequest>) -> Response {
    let username = match req.username.as_deref().filter(|s| !s.trim().is_empty()) {
        Some(u) => u,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("username is required")),
            )
                .into_response()
        }
    };
    let password = match req.password.as_deref().filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("password is required")),
            )
                .into_response()
        }
    };
    // Load user by username. To avoid user-enumeration timing, we always do
    // a dummy hash verify even when the user doesn't exist.
    let user = state.db.get_user_by_username(username).await.ok().flatten();
    let dummy_hash =
        "$argon2id$v=19$m=19456,t=2,p=1$AAAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAA";
    let stored = user
        .as_ref()
        .map(|u| u.password_hash.as_str())
        .unwrap_or(dummy_hash);
    let pw_ok = password::verify(password, stored).unwrap_or(false);

    let Some(user) = user else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(auth_json_err("invalid credentials")),
        )
            .into_response();
    };
    if !pw_ok || user.disabled {
        return (
            StatusCode::UNAUTHORIZED,
            Json(auth_json_err("invalid credentials")),
        )
            .into_response();
    }

    // TOTP check.
    if user.totp_enabled {
        let Some(code) = req.totp.as_deref().filter(|c| !c.is_empty()) else {
            return Json(LoginResponse {
                ok: false,
                totp_required: true,
                username: user.username,
            })
            .into_response();
        };
        let secret = user.totp_secret.as_deref().unwrap_or("");
        if !totp::verify(secret, code) {
            return (
                StatusCode::UNAUTHORIZED,
                Json(auth_json_err("invalid totp")),
            )
                .into_response();
        }
    }

    // Create session.
    let sess = match state.db.create_session(user.id, 30, None).await {
        Ok(s) => s,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let cookie = auth::set_cookie(&sess.token, state.config.secure_cookie);

    let _ = state
        .db
        .audit(Some(user.id), "login", &serde_json::json!({}), None)
        .await;

    (
        [(axum::http::header::SET_COOKIE, cookie)],
        Json(LoginResponse {
            ok: true,
            totp_required: false,
            username: user.username,
        }),
    )
        .into_response()
}

async fn logout(State(state): State<AppState>, req: axum::extract::Request) -> Response {
    if let Some(token) = auth::session::extract_token(&req) {
        let _ = state.db.delete_session(&token).await;
    }
    let cookie = auth::clear_cookie(state.config.secure_cookie);
    (
        [(axum::http::header::SET_COOKIE, cookie)],
        Json(serde_json::json!({"ok": true})),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub invite: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
}

async fn register(State(state): State<AppState>, Json(req): Json<RegisterRequest>) -> Response {
    // Validate inputs.
    let invite = match req.invite.as_deref().filter(|s| !s.trim().is_empty()) {
        Some(i) => i,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("invite token is required")),
            )
                .into_response()
        }
    };
    let username = match req.username.as_deref().filter(|s| !s.trim().is_empty()) {
        Some(u) => u,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("username is required")),
            )
                .into_response()
        }
    };
    let password = match req.password.as_deref().filter(|s| !s.is_empty()) {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("password is required")),
            )
                .into_response()
        }
    };
    if username.trim().len() < 3 || username.len() > 32 {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("username must be 3-32 chars")),
        )
            .into_response();
    }
    if !username
        .chars()
        .all(|c| c.is_alphanumeric() || c == '_' || c == '-' || c == '.')
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("username has invalid characters")),
        )
            .into_response();
    }
    if password.len() < 10 {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("password must be at least 10 chars")),
        )
            .into_response();
    }
    if password.len() > 1024 {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("password too long")),
        )
            .into_response();
    }

    // Validate invite.
    let created_by = match state.db.validate_invite(invite).await {
        Ok(Some(id)) => id,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("invalid or used invite")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    // Check username not taken.
    if let Ok(Some(_)) = state.db.get_user_by_username(username).await {
        return (StatusCode::CONFLICT, Json(auth_json_err("username taken"))).into_response();
    }

    let hash = match password::hash(password) {
        Ok(h) => h,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let user = match state
        .db
        .create_user(NewUser {
            username: username.to_string(),
            password_hash: hash,
        })
        .await
    {
        Ok(u) => u,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let _ = state.db.consume_invite(invite, user.id).await;
    let _ = state
        .db
        .audit(
            Some(user.id),
            "register",
            &serde_json::json!({"username": username, "invited_by": created_by}),
            None,
        )
        .await;

    Json(serde_json::json!({"ok": true, "username": user.username})).into_response()
}

#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub id: i64,
    pub username: String,
    pub role: String,
    pub totp_enabled: bool,
    pub provider_id: String,
    pub provider_command: String,
}

pub async fn me(CurrentUser(user): CurrentUser) -> Response {
    Json(MeResponse {
        id: user.id,
        username: user.username,
        role: user.role,
        totp_enabled: user.totp_enabled,
        provider_id: user.provider_id,
        provider_command: user.provider_command,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct UpdateMeRequest {
    pub provider_id: String,
    pub provider_command: String,
}

pub async fn update_me(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<UpdateMeRequest>,
) -> Response {
    let provider_id = req.provider_id.trim();
    if provider_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("provider_id is required")),
        )
            .into_response();
    }

    let valid_ids: std::collections::HashSet<_> = crate::providers::available_providers()
        .into_iter()
        .map(|p| p.id)
        .collect();
    if !valid_ids.contains(provider_id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("unknown provider")),
        )
            .into_response();
    }

    let provider_command = req.provider_command.trim();
    if provider_command.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("provider_command is required")),
        )
            .into_response();
    }

    if let Err(e) = state
        .db
        .set_provider(user.id, provider_id, provider_command)
        .await
    {
        return crate::api::map_err_internal(e).into_response();
    }

    Json(MeResponse {
        id: user.id,
        username: user.username,
        role: user.role,
        totp_enabled: user.totp_enabled,
        provider_id: provider_id.to_string(),
        provider_command: provider_command.to_string(),
    })
    .into_response()
}

#[derive(Debug, Serialize)]
pub struct TotpSetupResponse {
    pub otpauth_uri: String,
    pub secret: String,
}

/// Begin TOTP enrollment. Returns the secret + otpauth URI. The secret is
/// NOT enabled until verified with a valid code via `/totp/verify`.
pub async fn totp_setup(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    let setup = match totp::generate("devinorium", &user.username) {
        Ok(s) => s,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    // Store the pending secret (not yet enabled) so verify can confirm it.
    if let Err(e) = state
        .db
        .set_totp(user.id, Some(setup.secret_base32.clone()), false)
        .await
    {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(TotpSetupResponse {
        otpauth_uri: setup.otpauth_uri,
        secret: setup.secret_base32,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct TotpVerifyRequest {
    pub code: String,
}

pub async fn totp_verify(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<TotpVerifyRequest>,
) -> Response {
    let secret = match user.totp_secret {
        Some(ref s) if !user.totp_enabled => s.clone(),
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("no pending totp setup")),
            )
                .into_response();
        }
    };
    if !totp::verify(&secret, &req.code) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(auth_json_err("invalid totp code")),
        )
            .into_response();
    }
    if let Err(e) = state.db.set_totp(user.id, Some(secret), true).await {
        return crate::api::map_err_internal(e).into_response();
    }
    let _ = state
        .db
        .audit(Some(user.id), "totp.enable", &serde_json::json!({}), None)
        .await;
    Json(serde_json::json!({"ok": true})).into_response()
}

pub async fn totp_disable(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    if let Err(e) = state.db.set_totp(user.id, None, false).await {
        return crate::api::map_err_internal(e).into_response();
    }
    let _ = state
        .db
        .audit(Some(user.id), "totp.disable", &serde_json::json!({}), None)
        .await;
    Json(serde_json::json!({"ok": true})).into_response()
}

fn auth_json_err(msg: &str) -> serde_json::Value {
    serde_json::json!({ "error": msg })
}
