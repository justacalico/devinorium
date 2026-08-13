//! TOTP (RFC 6238) setup and verification.

use totp_rs::{Algorithm, Secret, TOTP};

/// A newly generated TOTP secret, with the otpauth URI for QR enrollment.
pub struct TotpSetup {
    pub secret_base32: String,
    pub otpauth_uri: String,
}

/// Generate a new random TOTP secret bound to `issuer`/`account`.
pub fn generate(issuer: &str, account: &str) -> anyhow::Result<TotpSetup> {
    let secret = Secret::generate_secret();
    let secret_bytes = secret
        .to_bytes()
        .map_err(|e| anyhow::anyhow!("totp secret decode: {e}"))?;
    let secret_b32 = secret.to_encoded().to_string();
    let totp = TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        secret_bytes,
        Some(issuer.to_string()),
        account.to_string(),
    )
    .map_err(|e| anyhow::anyhow!("totp init: {e}"))?;
    let uri = totp.get_url();
    Ok(TotpSetup {
        secret_base32: secret_b32,
        otpauth_uri: uri,
    })
}

/// Verify a 6-digit code against a base32-encoded secret.
///
/// Uses a ±1 step window to tolerate clock skew. Comparison is constant-time.
pub fn verify(secret_base32: &str, code: &str) -> bool {
    let secret = match Secret::Encoded(secret_base32.to_string()).to_bytes() {
        Ok(s) => s,
        Err(_) => return false,
    };
    let totp = match TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        secret,
        Some("devinorium".to_string()),
        "user".to_string(),
    ) {
        Ok(t) => t,
        Err(_) => return false,
    };
    let now = chrono::Utc::now().timestamp();
    let step = now / 30;
    let target = code.as_bytes();
    for delta in -1..=1i64 {
        let t = ((step + delta) * 30) as u64;
        let generated = totp.generate(t);
        if super::password::ct_eq(generated.as_bytes(), target) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_and_verify_current_code() {
        let setup = generate("devinorium", "alice").unwrap();
        let secret = Secret::Encoded(setup.secret_base32.clone())
            .to_bytes()
            .unwrap();
        let totp = TOTP::new(
            Algorithm::SHA1,
            6,
            1,
            30,
            secret,
            Some("devinorium".to_string()),
            "alice".to_string(),
        )
        .unwrap();
        let code = totp.generate_current().unwrap();
        assert!(verify(&setup.secret_base32, &code));
        assert!(!verify(&setup.secret_base32, "000000"));
    }
}
