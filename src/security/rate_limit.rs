//! In-memory token-bucket rate limiter, keyed by (bucket, client IP).
//!
//! Intended for sensitive endpoints (login, TOTP, registration, writes).
//! Not a distributed limiter — appropriate for a single-instance deployment.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use axum::extract::Request;
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use tokio::sync::Mutex;

use super::ip::from_req;

/// A shared rate limiter.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<HashMap<(String, String), Bucket>>>,
    capacity: u32,
    refill_per_sec: f64,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    /// Create a limiter with a given bucket capacity and refill rate.
    pub fn new(capacity: u32, refill_per_sec: f64) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            capacity,
            refill_per_sec,
        }
    }

    /// Try to consume one token for `(bucket, key)`. Returns true if allowed.
    pub async fn check(&self, bucket: &str, key: &str) -> bool {
        let mut map = self.inner.lock().await;
        let now = Instant::now();
        let entry = map.entry((bucket.to_string(), key.to_string())).or_insert(Bucket {
            tokens: self.capacity as f64,
            last: now,
        });
        let elapsed = now.duration_since(entry.last).as_secs_f64();
        entry.tokens = (entry.tokens + elapsed * self.refill_per_sec).min(self.capacity as f64);
        entry.last = now;
        if entry.tokens >= 1.0 {
            entry.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

/// A middleware layer binding a limiter to a named bucket.
#[derive(Clone)]
pub struct RateLimitLayer {
    pub limiter: RateLimiter,
    pub bucket: &'static str,
}

/// Middleware function: enforce rate limiting on the current route group.
pub async fn rate_limit(layer: RateLimitLayer, req: Request, next: Next) -> Response {
    let ip = from_req(&req);
    if !layer.limiter.check(layer.bucket, &ip).await {
        return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
    }
    next.run(req).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn allows_up_to_capacity_then_blocks() {
        let lim = RateLimiter::new(3, 0.0); // no refill
        assert!(lim.check("login", "1.2.3.4").await);
        assert!(lim.check("login", "1.2.3.4").await);
        assert!(lim.check("login", "1.2.3.4").await);
        assert!(!lim.check("login", "1.2.3.4").await);
    }

    #[tokio::test]
    async fn keys_are_independent() {
        let lim = RateLimiter::new(1, 0.0);
        assert!(lim.check("login", "1.1.1.1").await);
        assert!(lim.check("login", "2.2.2.2").await);
        assert!(!lim.check("login", "1.1.1.1").await);
    }
}
