//! Security hardening: security headers, rate limiting, CSRF origin checks,
//! and IP hashing for audit logs.
//!
//! These layers make Devinorium safe to expose to the public internet behind
//! a reverse proxy.

pub mod csrf;
pub mod headers;
pub mod ip;
pub mod paths;
pub mod rate_limit;

pub use csrf::csrf_origin_check;
pub use headers::security_headers;
pub use ip::{extract_client_ip, from_req as ip_from_req, ip_hash, ClientIp};
pub use rate_limit::{
    classify, global_weighted_rate_limit, weighted_rate_limit, EndpointClass, RateLimiter,
    WeightedRateLimit,
};
