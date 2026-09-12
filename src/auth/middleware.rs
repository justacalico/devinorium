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

use super::session::{extract_bearer_token, extract_cookie_token, CurrentUser};

/// Middleware: require a valid authenticated session with role `user`.
///
/// When the server runs in bundled local mode (`DEVINORIUM_LOCAL_TOKEN`), a
/// request whose bearer token matches the configured token is mapped onto the
/// `local` account directly — no session or password is involved. The local
/// account's `disabled` flag is ignored on this path: the token is only known
/// to the desktop app that spawned the server, so disabling the account would
/// brick the app with no way back in.
///
/// In `--dev` mode every request is mapped onto `local` unconditionally, so
/// the UI is usable with no login at all.
pub async fn require_auth(State(state): State<AppState>, req: Request, next: Next) -> Response {
    if state.config.dev_mode {
        return run_as_local(state, req, next).await;
    }

    let bearer = extract_bearer_token(&req);
    if let Some(expected) = state.config.local_token.as_deref() {
        if let Some(token) = bearer.as_deref() {
            if constant_time_eq::constant_time_eq(token.as_bytes(), expected.as_bytes()) {
                return run_as_local(state, req, next).await;
            }
        }
    }

    // Session lookup tries the explicit bearer credential first, then the
    // cookie — so a stale or proxy-injected header cannot shadow a valid
    // session cookie, and a stale cookie cannot shadow a working bearer.
    let mut session = None;
    let mut token = None;
    for candidate in [bearer, extract_cookie_token(&req)].into_iter().flatten() {
        if let Ok(Some(s)) = state.db.get_session(&candidate).await {
            session = Some(s);
            token = Some(candidate);
            break;
        }
    }
    let (Some(session), Some(token)) = (session, token) else {
        return unauthorized("invalid session");
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

/// Run the request as the passwordless `local` owner account, bypassing
/// session lookup and the account's disabled flag.
async fn run_as_local(state: AppState, req: Request, next: Next) -> Response {
    match state
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
    }
}

fn unauthorized(reason: &'static str) -> Response {
    tracing::warn!("auth rejected: {reason}");
    (StatusCode::UNAUTHORIZED, reason).into_response()
}
