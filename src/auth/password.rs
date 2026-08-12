//! Password hashing and verification using Argon2id.

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use subtle::ConstantTimeEq;

/// Hash a password with Argon2id and a random salt.
pub fn hash(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let hash = argon2
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("argon2 hash failed: {e}"))?;
    Ok(hash.to_string())
}

/// Verify a password against a stored Argon2 hash in constant time.
///
/// Returns `Ok(true)` if the password matches. Both "hash invalid" and
/// "no match" return `Ok(false)` so error messages don't leak whether the
/// account's hash was malformed.
pub fn verify(password: &str, stored: &str) -> anyhow::Result<bool> {
    let parsed = match PasswordHash::new(stored) {
        Ok(h) => h,
        Err(_) => return Ok(false),
    };
    let ok = Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok();
    // Constant-time-ish: argon2 already does constant-time compare internally,
    // and we never branch on user existence in callers.
    Ok(ok)
}

/// Constant-time comparison of two equal-length byte slices.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_and_verify_roundtrip() {
        let h = hash("correct horse battery staple").unwrap();
        assert!(verify("correct horse battery staple", &h).unwrap());
        assert!(!verify("wrong", &h).unwrap());
    }

    #[test]
    fn verify_malformed_hash_is_false() {
        assert!(!verify("x", "not-a-hash").unwrap());
    }
}
