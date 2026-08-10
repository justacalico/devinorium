//! Session cookie helpers and current-user extraction.

use axum::extract::{FromRequestParts, Request};
use axum::http::header::COOKIE;
use axum::http::StatusCode;

use crate::db::UserRow;

/// The name of the session cookie.
pub const COOKIE_NAME: &str = "devinorium_session";

/// The session token extracted from a request's Cookie header.
#[derive(Debug, Clone)]
pub struct SessionToken(pub String);

/// The authenticated user, injected by the auth middleware.
#[derive(Debug, Clone)]
pub struct CurrentUser(pub UserRow);

impl CurrentUser {
    pub fn id(&self) -> i64 {
        self.0.id
    }
}

#[axum::async_trait]
impl<S> FromRequestParts<S> for CurrentUser
where
    S: Send + Sync,
{
    type Rejection = (StatusCode, &'static str);

    async fn from_request_parts(
        parts: &mut axum::http::request::Parts,
        _state: &S,
    ) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<CurrentUser>()
            .cloned()
            .ok_or((StatusCode::UNAUTHORIZED, "not authenticated"))
    }
}

/// Extract the session token from a request's Cookie header, if present.
pub fn extract_token(req: &Request) -> Option<String> {
    let header = req.headers().get(COOKIE)?;
    let s = header.to_str().ok()?;
    for pair in s.split(';') {
        let pair = pair.trim();
        if let Some(rest) = pair.strip_prefix(&format!("{COOKIE_NAME}=")) {
            return Some(rest.to_string());
        }
    }
    None
}

/// Build a Set-Cookie header value for a session token.
pub fn set_cookie(token: &str, secure: bool) -> String {
    let flags = "HttpOnly; SameSite=Strict; Path=/";
    let secure_flag = if secure { "; Secure" } else { "" };
    format!("{COOKIE_NAME}={token}; {flags}{secure_flag}; Max-Age=2592000")
}

/// Build a Set-Cookie header value that clears the session cookie.
pub fn clear_cookie(secure: bool) -> String {
    let flags = "HttpOnly; SameSite=Strict; Path=/";
    let secure_flag = if secure { "; Secure" } else { "" };
    format!("{COOKIE_NAME}=; {flags}{secure_flag}; Max-Age=0")
}
