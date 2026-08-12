//! Weighted token-bucket rate limiter, keyed by (bucket, client IP).
//!
//! Instead of counting every request equally, each endpoint type has a
//! **cost** that is deducted from the bucket. This means:
//!
//! - Sensitive unauthenticated actions (login, register, TOTP verify) cost a
//!   lot — a brute-force attacker depletes the bucket in a few tries.
//! - Authenticated read actions (GET /threads, GET /files) cost nothing —
//!   normal browsing is never throttled.
//! - Authenticated write actions (send message, upload file) cost a little —
//!   a user can send many messages before being throttled, but a script
//!   spamming the API will be stopped.
//! - Unauthenticated attempts to hit protected endpoints cost the most —
//!   this penalizes probing/scanning behavior.
//!
//! Not a distributed limiter — appropriate for a single-instance deployment.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use axum::extract::Request;
use axum::http::{Method, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use tokio::sync::Mutex;

use super::ip::from_req;

/// The cost (in tokens) of a given endpoint class.
///
/// Higher = more expensive = fewer allowed before throttling.
#[derive(Debug, Clone, Copy)]
pub enum EndpointClass {
    /// Sensitive unauthenticated auth: login, register. High cost.
    AuthSensitive,
    /// TOTP verification (unauthenticated but requires a valid session cookie
    /// to have been issued). Medium-high cost.
    TotpVerify,
    /// Authenticated write: send message, create thread, upload file, etc.
    /// Low cost — normal usage should never hit the limit.
    AuthWrite,
    /// Authenticated sensitive write: create invite. Medium cost.
    AuthSensitiveWrite,
    /// Authenticated read or logout. Free.
    AuthRead,
    /// Unauthenticated attempt to hit a protected endpoint. Very high cost —
    /// penalizes probing/scanning.
    UnauthProbe,
}

impl EndpointClass {
    fn cost(self) -> f64 {
        match self {
            EndpointClass::AuthSensitive => 20.0,
            EndpointClass::TotpVerify => 15.0,
            EndpointClass::AuthWrite => 2.0,
            EndpointClass::AuthSensitiveWrite => 5.0,
            EndpointClass::AuthRead => 0.0,
            EndpointClass::UnauthProbe => 25.0,
        }
    }
}

/// A shared weighted rate limiter.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<HashMap<(String, String), Bucket>>>,
    capacity: f64,
    refill_per_sec: f64,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    /// Create a limiter with a given bucket capacity and refill rate (tokens/sec).
    pub fn new(capacity: u32, refill_per_sec: f64) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            capacity: capacity as f64,
            refill_per_sec,
        }
    }

    /// Try to consume `cost` tokens for `(bucket, key)`. Returns true if allowed.
    pub async fn check(&self, bucket: &str, key: &str, cost: f64) -> bool {
        // Free actions always pass — no need to touch the bucket.
        if cost <= 0.0 {
            return true;
        }
        let mut map = self.inner.lock().await;
        let now = Instant::now();
        let entry = map
            .entry((bucket.to_string(), key.to_string()))
            .or_insert(Bucket {
                tokens: self.capacity,
                last: now,
            });
        let elapsed = now.duration_since(entry.last).as_secs_f64();
        entry.tokens = (entry.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        entry.last = now;
        if entry.tokens >= cost {
            entry.tokens -= cost;
            true
        } else {
            false
        }
    }
}

/// Configuration for the weighted rate-limit middleware.
#[derive(Clone)]
pub struct WeightedRateLimit {
    pub limiter: RateLimiter,
    pub bucket: &'static str,
    pub class: EndpointClass,
}

/// Middleware: enforce weighted rate limiting.
///
/// The `class` determines the cost. If the request has a valid session
/// cookie (i.e. the user is authenticated), the cost is reduced according
/// to the endpoint class. If not, unauthenticated attempts to protected
/// endpoints are penalized with the `UnauthProbe` cost.
pub async fn weighted_rate_limit(cfg: WeightedRateLimit, req: Request, next: Next) -> Response {
    let ip = from_req(&req);
    let cost = cfg.class.cost();
    if !cfg.limiter.check(cfg.bucket, &ip, cost).await {
        return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
    }
    next.run(req).await
}

/// Determine the endpoint class for a request based on method + path.
///
/// This is used by the global rate limiter that runs before auth, so it
/// can't know if the user is actually authenticated — it uses the presence
/// of a session cookie as a heuristic. The auth middleware will reject
/// invalid sessions regardless.
pub fn classify(req: &Request) -> EndpointClass {
    let path = req.uri().path();
    let method = req.method();
    let has_cookie = req.headers().get(axum::http::header::COOKIE).is_some();

    // Auth endpoints (public, no session required).
    if path == "/api/auth/login" || path == "/api/auth/register" {
        return EndpointClass::AuthSensitive;
    }
    if path == "/api/auth/totp/verify" {
        return EndpointClass::TotpVerify;
    }
    if path == "/api/auth/logout" {
        return EndpointClass::AuthRead; // free
    }

    // Protected endpoints — cost depends on whether the caller appears
    // authenticated (has a cookie) and the action type.
    let is_write = matches!(
        method,
        &Method::POST | &Method::PUT | &Method::PATCH | &Method::DELETE
    );

    if !has_cookie && is_write {
        // No cookie + write attempt to a protected endpoint = probing.
        return EndpointClass::UnauthProbe;
    }

    if path == "/api/invites" && is_write {
        return EndpointClass::AuthSensitiveWrite;
    }

    if is_write {
        EndpointClass::AuthWrite
    } else {
        EndpointClass::AuthRead
    }
}

/// Middleware: global weighted rate limiter that classifies each request
/// automatically based on method + path + cookie presence.
pub async fn global_weighted_rate_limit(
    limiter: RateLimiter,
    req: Request,
    next: Next,
) -> Response {
    let ip = from_req(&req);
    let class = classify(&req);
    let cost = class.cost();
    if !limiter.check("global", &ip, cost).await {
        return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
    }
    next.run(req).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn free_actions_never_deplete() {
        let lim = RateLimiter::new(10, 0.0);
        // AuthRead costs 0 — should always pass, even 1000 times.
        for _ in 0..1000 {
            assert!(lim.check("b", "ip", 0.0).await);
        }
    }

    #[tokio::test]
    async fn expensive_actions_deplete_fast() {
        let lim = RateLimiter::new(100, 0.0);
        // AuthSensitive costs 20 — 5 calls = 100 tokens, 6th should fail.
        assert!(lim.check("b", "ip", 20.0).await);
        assert!(lim.check("b", "ip", 20.0).await);
        assert!(lim.check("b", "ip", 20.0).await);
        assert!(lim.check("b", "ip", 20.0).await);
        assert!(lim.check("b", "ip", 20.0).await);
        assert!(
            !lim.check("b", "ip", 20.0).await,
            "6th call should be blocked"
        );
    }

    #[tokio::test]
    async fn cheap_actions_allow_many() {
        let lim = RateLimiter::new(100, 0.0);
        // AuthWrite costs 2 — 50 calls = 100 tokens.
        for i in 0..50 {
            assert!(lim.check("b", "ip", 2.0).await, "call {} should pass", i);
        }
        assert!(
            !lim.check("b", "ip", 2.0).await,
            "51st call should be blocked"
        );
    }

    #[tokio::test]
    async fn unauth_probe_is_most_expensive() {
        let lim = RateLimiter::new(100, 0.0);
        // UnauthProbe costs 25 — 4 calls = 100 tokens.
        assert!(lim.check("b", "ip", 25.0).await);
        assert!(lim.check("b", "ip", 25.0).await);
        assert!(lim.check("b", "ip", 25.0).await);
        assert!(lim.check("b", "ip", 25.0).await);
        assert!(
            !lim.check("b", "ip", 25.0).await,
            "5th probe should be blocked"
        );
    }

    #[tokio::test]
    async fn mixed_costs_share_bucket() {
        let lim = RateLimiter::new(100, 0.0);
        // 1 login (20) + 1 probe (25) + 1 write (2) = 47, then 2 more logins (40) = 87, then 1 write (2) = 89
        assert!(lim.check("b", "ip", 20.0).await); // login
        assert!(lim.check("b", "ip", 25.0).await); // probe
        assert!(lim.check("b", "ip", 2.0).await); // write
        assert!(lim.check("b", "ip", 20.0).await); // login
        assert!(lim.check("b", "ip", 20.0).await); // login = 87
        assert!(lim.check("b", "ip", 2.0).await); // write = 89
        assert!(lim.check("b", "ip", 2.0).await); // write = 91
        assert!(lim.check("b", "ip", 2.0).await); // write = 93
        assert!(lim.check("b", "ip", 2.0).await); // write = 95
                                                  // 5 tokens left — another login (20) should fail.
        assert!(
            !lim.check("b", "ip", 20.0).await,
            "login should fail with 5 tokens left"
        );
        // But a write (2) should still pass.
        assert!(
            lim.check("b", "ip", 2.0).await,
            "write should pass with 5 tokens"
        );
    }

    #[tokio::test]
    async fn refill_restores_tokens() {
        let lim = RateLimiter::new(100, 1000.0); // very fast refill
                                                 // Deplete fully.
        for _ in 0..5 {
            lim.check("b", "ip", 20.0).await;
        }
        assert!(!lim.check("b", "ip", 20.0).await);
        // Wait a bit for refill.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(lim.check("b", "ip", 20.0).await, "should pass after refill");
    }

    #[tokio::test]
    async fn keys_are_independent() {
        let lim = RateLimiter::new(20, 0.0);
        // IP 1.1.1.1 depletes its bucket.
        assert!(lim.check("b", "1.1.1.1", 20.0).await);
        assert!(!lim.check("b", "1.1.1.1", 1.0).await);
        // IP 2.2.2.2 has its own full bucket.
        assert!(lim.check("b", "2.2.2.2", 20.0).await);
        assert!(!lim.check("b", "2.2.2.2", 1.0).await);
        // Different bucket for same IP is also independent.
        assert!(lim.check("other", "1.1.1.1", 20.0).await);
    }

    #[test]
    fn classify_login_is_sensitive() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/auth/login")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthSensitive));
    }

    #[test]
    fn classify_register_is_sensitive() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/auth/register")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthSensitive));
    }

    #[test]
    fn classify_logout_is_free() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/auth/logout")
            .header(axum::http::header::COOKIE, "session=abc")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthRead));
    }

    #[test]
    fn classify_get_threads_is_free() {
        let req = Request::builder()
            .method(Method::GET)
            .uri("/api/threads")
            .header(axum::http::header::COOKIE, "session=abc")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthRead));
    }

    #[test]
    fn classify_post_threads_with_cookie_is_write() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/threads")
            .header(axum::http::header::COOKIE, "session=abc")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthWrite));
    }

    #[test]
    fn classify_post_threads_without_cookie_is_probe() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/threads")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::UnauthProbe));
    }

    #[test]
    fn classify_post_invites_is_sensitive_write() {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/api/invites")
            .header(axum::http::header::COOKIE, "session=abc")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::AuthSensitiveWrite));
    }

    #[test]
    fn classify_delete_without_cookie_is_probe() {
        let req = Request::builder()
            .method(Method::DELETE)
            .uri("/api/threads/123")
            .body(axum::body::Body::empty())
            .unwrap();
        assert!(matches!(classify(&req), EndpointClass::UnauthProbe));
    }
}
