//! Authentication API routes: login, logout, `me`, TOTP setup/verify/disable.
//!
//! Registration is now owner-managed via the accounts API.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::{self, password, session::CurrentUser, totp};
use crate::AppState;

/// Public (unauthenticated) auth routes.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/auth/login", post(login))
        .route("/api/auth/logout", post(logout))
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
    pub token: String,
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
                token: String::new(),
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
    let sess = match state.db.create_session(user.id, 30, None, None).await {
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
            token: sess.token,
        }),
    )
        .into_response()
}

async fn logout(State(state): State<AppState>, req: axum::extract::Request) -> Response {
    for token in [
        auth::session::extract_bearer_token(&req),
        auth::session::extract_cookie_token(&req),
    ]
    .into_iter()
    .flatten()
    {
        let _ = state.db.delete_session(&token).await;
    }
    let cookie = auth::clear_cookie(state.config.secure_cookie);
    (
        [(axum::http::header::SET_COOKIE, cookie)],
        Json(serde_json::json!({"ok": true})),
    )
        .into_response()
}

#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub id: i64,
    pub username: String,
    pub role: String,
    pub is_owner: bool,
    pub totp_enabled: bool,
    pub provider_id: String,
    pub provider_command: String,
    /// CLI command configured per provider id. Providers absent from the map
    /// use their built-in default command.
    pub provider_commands: std::collections::HashMap<String, String>,
}

fn me_response(user: crate::db::UserRow) -> MeResponse {
    let provider_commands = user.provider_commands_map();
    MeResponse {
        id: user.id,
        username: user.username,
        role: user.role,
        is_owner: user.is_owner,
        totp_enabled: user.totp_enabled,
        provider_id: user.provider_id,
        provider_command: user.provider_command,
        provider_commands,
    }
}

pub async fn me(CurrentUser(user): CurrentUser) -> Response {
    Json(me_response(user)).into_response()
}

#[derive(Debug, Deserialize)]
pub struct UpdateMeRequest {
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub provider_command: Option<String>,
    /// Optional per-provider command overrides, applied on top of the stored
    /// map. An empty command removes the override.
    #[serde(default)]
    pub provider_commands: Option<std::collections::HashMap<String, String>>,
}

pub async fn update_me(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<UpdateMeRequest>,
) -> Response {
    let provider_id = req
        .provider_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    if req.provider_id.is_some() && provider_id.is_none() {
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
    if let Some(pid) = provider_id {
        if !valid_ids.contains(pid) {
            return (
                StatusCode::BAD_REQUEST,
                Json(auth_json_err("unknown provider")),
            )
                .into_response();
        }
    }

    let provider_command = req
        .provider_command
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    if req.provider_command.is_some() && provider_command.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            Json(auth_json_err("provider_command is required")),
        )
            .into_response();
    }

    // The provider the command applies to: the requested one, or the current
    // default when only a command update was sent.
    let effective_id = provider_id.unwrap_or(&user.provider_id);

    // Build the command-map patch. Explicit entries win; an empty command
    // removes the override (json_patch treats null as key removal).
    let mut patch = serde_json::Map::new();
    if let Some(commands) = &req.provider_commands {
        for (pid, command) in commands {
            let pid = pid.trim();
            if !valid_ids.contains(pid) {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(auth_json_err("unknown provider in provider_commands")),
                )
                    .into_response();
            }
            let command = command.trim();
            patch.insert(
                pid.to_string(),
                if command.is_empty() {
                    serde_json::Value::Null
                } else {
                    serde_json::Value::String(command.to_string())
                },
            );
        }
    }

    // When the default provider changes without an explicit command, prefer
    // the stored (or newly patched) override for it and fall back to the
    // built-in default command.
    let provider_command = match provider_command {
        Some(c) => Some(c.to_string()),
        None if provider_id.is_some() => {
            let resolved = patch
                .get(effective_id)
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .unwrap_or_else(|| {
                    let stored = user.command_for_provider(effective_id);
                    if stored.is_empty() {
                        crate::providers::default_command(effective_id).to_string()
                    } else {
                        stored
                    }
                });
            Some(resolved)
        }
        None => None,
    };

    if let Some(command) = &provider_command {
        // Keep the map in sync with the legacy column so the default
        // provider's command is recorded under its own id.
        patch.insert(
            effective_id.to_string(),
            serde_json::Value::String(command.clone()),
        );
        // Preserve the outgoing provider's command under its own id so a
        // custom binary path is not lost when the default provider changes.
        if provider_id.is_some() && effective_id != user.provider_id {
            let outgoing = user.provider_command.trim();
            if !outgoing.is_empty() {
                patch.insert(
                    user.provider_id.clone(),
                    serde_json::Value::String(outgoing.to_string()),
                );
            }
        }
    }

    if provider_id.is_some() || provider_command.is_some() || !patch.is_empty() {
        if let Err(e) = state
            .db
            .update_provider_settings(user.id, provider_id, provider_command.as_deref(), &patch)
            .await
        {
            return crate::api::map_err_internal(e).into_response();
        }
        // The stored probe result belongs to the previous command; drop it so
        // the next provider list re-checks the new one.
        if let Some(command) = &provider_command {
            state.provider_status.invalidate(command);
        }
        for value in patch.values() {
            if let Some(command) = value.as_str() {
                state.provider_status.invalidate(command);
            }
        }
    }

    let user = match state.db.get_user_by_id(user.id).await {
        Ok(Some(u)) => u,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(auth_json_err("user not found"))).into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    Json(me_response(user)).into_response()
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
