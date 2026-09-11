//! Authentication & authorization middleware.
//!
//! Every protected route passes through [`require_auth`], which:
//! 1. Reads the session cookie.
//! 2. Loads the session + user from the database.
//! 3. Enforces that the user exists, is not disabled, and has the only
//!    permitted role (`user`). Any other role is rejected — there is no
//!    admin role and no escalation path.
//! 4. Injects [`CurrentUser`] into request extensions for handlers.
//! 5. Touches the session's last-seen timestamp.

use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use chrono::Utc;

use crate::AppState;

use super::session::{extract_token, CurrentUser};

/// Middleware: require a valid authenticated session with role `user`.
///
/// When the server runs in bundled local mode (`DEVINORIUM_LOCAL_TOKEN`), a
/// request whose bearer token matches the configured token is mapped onto the
/// `local` account directly — no session or password is involved. The local
/// account's `disabled` flag is ignored on this path: the token is only known
/// to the desktop app that spawned the server, so disabling the account would
/// brick the app with no way back in.
pub async fn require_auth(State(state): State<AppState>, req: Request, next: Next) -> Response {
    if let Some(expected) = state.config.local_token.as_deref() {
        if let Some(token) = extract_token(&req) {
            if constant_time_eq::constant_time_eq(token.as_bytes(), expected.as_bytes()) {
                return match state
                    .db
                    .get_user_by_username(super::bootstrap::LOCAL_USERNAME)
                    .await
                {
                    Ok(Some(user)) => {
                        let mut req = req;
                        req.extensions_mut().insert(CurrentUser(user));
                        next.run(req).await
                    }
                    _ => unauthorized("local user missing"),
                };
            }
        }
    }

    let Some(token) = extract_token(&req) else {
        return unauthorized("no session");
    };

    let session = match state.db.get_session(&token).await {
        Ok(Some(s)) => s,
        _ => return unauthorized("invalid session"),
    };

    let user = match state.db.get_user_by_id(session.user_id).await {
        Ok(Some(u)) => u,
        _ => return unauthorized("no user"),
    };

    // Role check: the only permitted role is "user". This is belt-and-suspenders
    // since the DB CHECK constraint already enforces it, but defense-in-depth
    // means we check it here too.
    if user.role != "user" {
        // Revoke the session for a non-user role (should be impossible).
        let _ = state.db.delete_session(&token).await;
        return unauthorized("role not permitted");
    }
    if user.disabled {
        let _ = state.db.delete_session(&token).await;
        return unauthorized("disabled");
    }

    // Touch last-seen (best-effort, non-blocking on error).
    let _ = state.db.touch_session(&token).await;

    let now = Utc::now().to_rfc3339();
    tracing::debug!(user_id = user.id, "auth ok at {now}");

    let mut req = req;
    req.extensions_mut().insert(CurrentUser(user));
    next.run(req).await
}

fn unauthorized(reason: &'static str) -> Response {
    tracing::warn!("auth rejected: {reason}");
    (StatusCode::UNAUTHORIZED, reason).into_response()
}
