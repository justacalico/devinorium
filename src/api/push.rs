//! Web Push subscription API.
//!
//! The browser subscribes through the Push API and registers the resulting
//! endpoint+keys here; the backend then delivers run events through the push
//! service even while the app is closed. `GET /api/push/vapid-key` hands out
//! the instance's VAPID public key (the `applicationServerKey`).

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put};
use axum::{Json, Router};
use serde::Deserialize;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/push/vapid-key", get(vapid_key))
        .route("/api/push/subscriptions", put(subscribe))
        .route(
            "/api/push/subscriptions",
            axum::routing::delete(unsubscribe),
        )
        .route("/api/push/subscriptions", get(list_subscriptions))
        .route("/api/push/test", axum::routing::post(test_push))
}

/// The instance's VAPID public key. 404 when push is not initialized, which
/// tells the client to fall back to in-page notifications only.
async fn vapid_key(State(state): State<AppState>) -> Response {
    match state.push.vapid_public_key() {
        Some(key) => Json(serde_json::json!({"public_key": key})).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("push not enabled")),
        )
            .into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct SubscribeRequest {
    pub endpoint: String,
    pub keys: SubscribeKeys,
    /// BCP-47-ish language code captured at subscribe time; pushes are
    /// rendered in it server-side.
    pub lang: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SubscribeKeys {
    pub p256dh: String,
    pub auth: String,
}

fn valid_b64url(s: &str, min: usize, max: usize) -> bool {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    URL_SAFE_NO_PAD
        .decode(s.trim_end_matches('='))
        .map(|v| (min..=max).contains(&v.len()))
        .unwrap_or(false)
}

async fn subscribe(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SubscribeRequest>,
) -> Response {
    let endpoint = req.endpoint.trim();
    // Only http(s) endpoints are push services; anything else would let a
    // subscriber turn the server into an SSRF client.
    if crate::push::crypto::endpoint_origin(endpoint).is_err() || endpoint.len() > 2048 {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("invalid endpoint")),
        )
            .into_response();
    }
    // p256dh is the uncompressed 65-byte P-256 point; auth is a short secret.
    if !valid_b64url(&req.keys.p256dh, 65, 65) || !valid_b64url(&req.keys.auth, 1, 64) {
        return (StatusCode::BAD_REQUEST, Json(ApiError::new("invalid keys"))).into_response();
    }
    let lang = req
        .lang
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= 16)
        .unwrap_or("en");
    match state
        .db
        .upsert_push_subscription(
            user.id,
            endpoint,
            &req.keys.p256dh,
            &req.keys.auth,
            lang,
            "",
        )
        .await
    {
        Ok(()) => (StatusCode::CREATED, Json(serde_json::json!({"ok": true}))).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct UnsubscribeRequest {
    pub endpoint: String,
}

async fn unsubscribe(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<UnsubscribeRequest>,
) -> Response {
    match state
        .db
        .delete_push_subscription(user.id, req.endpoint.trim())
        .await
    {
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// The caller's subscriptions (endpoint + metadata only — keys stay
/// server-side so listing rows never leaks them into responses).
async fn list_subscriptions(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    match state.db.push_subscriptions_for_user(user.id).await {
        Ok(rows) => Json(serde_json::json!({
            "subscriptions": rows.iter().map(|r| serde_json::json!({
                "endpoint": r.endpoint,
                "lang": r.lang,
                "created_at": r.created_at,
                "updated_at": r.updated_at,
            })).collect::<Vec<_>>()
        }))
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Send a test push to every subscription the caller owns. Returns the
/// number of endpoints that accepted it; stale ones are pruned en route.
async fn test_push(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !state.push.enabled() {
        return (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("push not enabled")),
        )
            .into_response();
    }
    let sent = state.push.send_test(user.id).await;
    Json(serde_json::json!({"sent": sent})).into_response()
}
