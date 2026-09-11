//! Session cookie helpers and current-user extraction.

use axum::extract::{FromRequestParts, Request};
use axum::http::header::{AUTHORIZATION, COOKIE};
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

/// Extract the session token from a request's `Authorization: Bearer` header
/// or `devinorium_session` cookie. The explicit header wins so a stale cookie
/// cannot shadow a valid bearer credential.
pub fn extract_token(req: &Request) -> Option<String> {
    extract_bearer_token(req).or_else(|| extract_cookie_token(req))
}

fn extract_cookie_token(req: &Request) -> Option<String> {
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

fn extract_bearer_token(req: &Request) -> Option<String> {
    let header = req.headers().get(AUTHORIZATION)?;
    let s = header.to_str().ok()?;
    let rest = s.strip_prefix("Bearer ")?.trim();
    if rest.is_empty() {
        return None;
    }
    Some(rest.to_string())
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;

    fn req() -> Request {
        Request::builder().uri("/").body(Body::empty()).unwrap()
    }

    #[test]
    fn extract_from_cookie() {
        let req = Request::builder()
            .uri("/")
            .header("cookie", "other=1; devinorium_session=abc123; x=2")
            .body(Body::empty())
            .unwrap();
        assert_eq!(extract_token(&req).unwrap(), "abc123");
    }

    #[test]
    fn extract_from_authorization_bearer() {
        let req = Request::builder()
            .uri("/")
            .header("authorization", "Bearer tok_123")
            .body(Body::empty())
            .unwrap();
        assert_eq!(extract_token(&req).unwrap(), "tok_123");
    }

    #[test]
    fn cookie_takes_precedence_over_bearer() {
        let req = Request::builder()
            .uri("/")
            .header("cookie", "devinorium_session=from_cookie")
            .header("authorization", "Bearer from_header")
            .body(Body::empty())
            .unwrap();
        assert_eq!(extract_token(&req).unwrap(), "from_cookie");
    }

    #[test]
    fn missing_token_returns_none() {
        assert!(extract_token(&req()).is_none());
    }

    #[test]
    fn malformed_bearer_returns_none() {
        let req = Request::builder()
            .uri("/")
            .header("authorization", "tok_123")
            .body(Body::empty())
            .unwrap();
        assert!(extract_token(&req).is_none());
    }
}
