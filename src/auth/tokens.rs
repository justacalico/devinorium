//! Cryptographically secure random token generation.

use rand::{distributions::Alphanumeric, Rng};

/// Generate a URL-safe random token of `n` bytes (encoded as base64url).
pub fn random_token(n: usize) -> String {
    use rand::RngCore;
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    base64_url_encode(&buf)
}

/// Generate a random alphanumeric string (for opaque ids where base64 is undesirable).
pub fn random_alnum(n: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(n)
        .map(char::from)
        .collect()
}

/// SHA-256 of a session token, hex-encoded. Sessions are stored by hash so a
/// database leak does not expose live credentials; the plaintext token only
/// ever exists in the cookie/response that created it.
pub fn token_hash(token: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// base64url encoding without padding.
pub fn base64_url_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// base64url decoding.
pub fn base64_url_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s)
}
