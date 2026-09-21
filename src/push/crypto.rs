//! Web Push cryptography: VAPID (RFC 8292) JWT signing and the aes128gcm
//! content encoding (RFC 8291 + RFC 8188) push services expect.

use anyhow::{bail, Context};
use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::aead::{self, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::agreement::{self, EphemeralPrivateKey, UnparsedPublicKey};
use ring::hkdf::{self, Okm, Prk, Salt};
use ring::rand::SecureRandom;
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

/// A persisted VAPID keypair: the PKCS#8 document plus the uncompressed
/// P-256 public key (the `applicationServerKey` clients subscribe with).
pub struct VapidKeys {
    pub pkcs8: Vec<u8>,
    pub public_key: Vec<u8>,
}

impl VapidKeys {
    pub fn generate() -> anyhow::Result<Self> {
        let rng = ring::rand::SystemRandom::new();
        let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
            .map_err(|_| anyhow::anyhow!("vapid key generation failed"))?;
        let kp = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, doc.as_ref(), &rng)
            .map_err(|e| anyhow::anyhow!("vapid key parse failed: {e}"))?;
        Ok(Self {
            pkcs8: doc.as_ref().to_vec(),
            public_key: kp.public_key().as_ref().to_vec(),
        })
    }

    pub fn from_pkcs8(pkcs8: &[u8]) -> anyhow::Result<Self> {
        let rng = ring::rand::SystemRandom::new();
        let kp = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8, &rng)
            .map_err(|e| anyhow::anyhow!("invalid vapid key: {e}"))?;
        Ok(Self {
            pkcs8: pkcs8.to_vec(),
            public_key: kp.public_key().as_ref().to_vec(),
        })
    }

    fn key_pair(&self) -> anyhow::Result<EcdsaKeyPair> {
        let rng = ring::rand::SystemRandom::new();
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &self.pkcs8, &rng)
            .map_err(|e| anyhow::anyhow!("invalid vapid key: {e}"))
    }
}

fn b64url(data: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(data)
}

fn b64url_decode(s: &str) -> anyhow::Result<Vec<u8>> {
    // Subscriptions may arrive padded or unpadded depending on the client.
    URL_SAFE_NO_PAD
        .decode(s.trim_end_matches('='))
        .or_else(|_| URL_SAFE.decode(s))
        .context("invalid base64url")
}

/// The `aud` claim of a VAPID JWT is the push endpoint's origin
/// (scheme://authority), per RFC 8292.
pub fn endpoint_origin(endpoint: &str) -> anyhow::Result<String> {
    let (scheme, rest) = endpoint
        .split_once("://")
        .context("endpoint has no scheme")?;
    if scheme != "https" && scheme != "http" {
        bail!("endpoint scheme must be http(s)");
    }
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        bail!("endpoint has no authority");
    }
    Ok(format!("{scheme}://{authority}"))
}

/// Sign a VAPID JWT for `aud` expiring in ~12 hours (the spec caps exp at
/// +24h; staying under keeps clock-skewed hosts working).
pub fn vapid_jwt(endpoint: &str, subject: &str, keys: &VapidKeys) -> anyhow::Result<String> {
    let rng = ring::rand::SystemRandom::new();
    let kp = keys.key_pair()?;
    let aud = endpoint_origin(endpoint)?;
    let exp = chrono::Utc::now().timestamp() + 12 * 60 * 60;
    let header = b64url(br#"{"typ":"JWT","alg":"ES256"}"#);
    let claims = b64url(
        serde_json::json!({"aud": aud, "exp": exp, "sub": subject})
            .to_string()
            .as_bytes(),
    );
    let signing_input = format!("{header}.{claims}");
    let sig = kp
        .sign(&rng, signing_input.as_bytes())
        .map_err(|_| anyhow::anyhow!("vapid signing failed"))?;
    Ok(format!("{signing_input}.{}", b64url(sig.as_ref())))
}

/// The value of the `Authorization: vapid t=..., k=...` header.
pub fn vapid_authorization(
    endpoint: &str,
    subject: &str,
    keys: &VapidKeys,
) -> anyhow::Result<String> {
    let jwt = vapid_jwt(endpoint, subject, keys)?;
    Ok(format!("vapid t={jwt}, k={}", b64url(&keys.public_key)))
}

fn hkdf_extract(salt: &[u8], ikm: &[u8]) -> Prk {
    Salt::new(hkdf::HKDF_SHA256, salt).extract(ikm)
}

/// HKDF-Expand truncated to `len` bytes. Every expansion here needs at most
/// one SHA-256 block, so a 32-byte OKM sliced to `len` is the same output a
/// native fixed-length expand would produce.
fn hkdf_expand(prk: &Prk, info: &[u8], len: usize) -> anyhow::Result<Vec<u8>> {
    debug_assert!(len <= 32);
    let info = [info];
    let okm: Okm<'_, hkdf::Algorithm> = prk
        .expand(&info, hkdf::HKDF_SHA256)
        .map_err(|_| anyhow::anyhow!("hkdf expand failed"))?;
    let mut out = vec![0u8; 32];
    okm.fill(&mut out)
        .map_err(|_| anyhow::anyhow!("hkdf fill failed"))?;
    out.truncate(len);
    Ok(out)
}

/// Encrypt `payload` for a subscription into an aes128gcm body: the
/// salt/rs/keyid header followed by a single sealed record.
///
/// `p256dh`/`auth` are the subscription's base64url keys; `as_public_key` is
/// returned so callers can embed it — it is already inside the body, but the
/// reference is useful for tests.
pub fn encrypt_payload(p256dh: &str, auth_secret: &str, payload: &[u8]) -> anyhow::Result<Vec<u8>> {
    let rng = ring::rand::SystemRandom::new();
    let ua_public = b64url_decode(p256dh)?;
    if ua_public.len() != 65 || ua_public[0] != 0x04 {
        bail!("p256dh must be a 65-byte uncompressed P-256 point");
    }
    let auth = b64url_decode(auth_secret)?;
    if auth.is_empty() || auth.len() > 64 {
        bail!("auth secret must be 1-64 bytes");
    }

    let as_private = EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng)
        .map_err(|_| anyhow::anyhow!("ecdh keygen failed"))?;
    let as_public = as_private
        .compute_public_key()
        .map_err(|_| anyhow::anyhow!("ecdh pubkey failed"))?;
    let peer = UnparsedPublicKey::new(&agreement::ECDH_P256, ua_public.as_slice());
    let shared = agreement::agree_ephemeral(as_private, &peer, |s| s.to_vec())
        .map_err(|_| anyhow::anyhow!("ecdh failed"))?;

    // RFC 8291 §3.4: IKM = HKDF-Expand(HKDF-Extract(auth, ecdh),
    //   "WebPush: info" || 0x00 || ua_public || as_public, 32).
    let mut info = b"WebPush: info\x00".to_vec();
    info.extend_from_slice(&ua_public);
    info.extend_from_slice(as_public.as_ref());
    let ikm = hkdf_expand(&hkdf_extract(&auth, &shared), &info, 32)?;

    let mut salt = [0u8; 16];
    rng.fill(&mut salt)
        .map_err(|_| anyhow::anyhow!("rng failed"))?;
    let prk = hkdf_extract(&salt, &ikm);
    let cek = hkdf_expand(&prk, b"Content-Encoding: aes128gcm\x00", 16)?;
    let nonce_bytes = hkdf_expand(&prk, b"Content-Encoding: nonce\x00", 12)?;

    // One record: plaintext followed by the 0x02 last-record delimiter.
    let mut record = Vec::with_capacity(payload.len() + 17);
    record.extend_from_slice(payload);
    record.push(0x02);
    let key = LessSafeKey::new(
        UnboundKey::new(&aead::AES_128_GCM, &cek)
            .map_err(|_| anyhow::anyhow!("aead key failed"))?,
    );
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&nonce_bytes);
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce),
        Aad::empty(),
        &mut record,
    )
    .map_err(|_| anyhow::anyhow!("aead seal failed"))?;

    let mut body = Vec::with_capacity(16 + 4 + 1 + as_public.as_ref().len() + record.len());
    body.extend_from_slice(&salt);
    // Record size only bounds non-final records; a single record just needs
    // rs >= ciphertext length. 4096 covers any notification payload.
    let rs = (record.len() as u32 + 1).max(4096);
    body.extend_from_slice(&rs.to_be_bytes());
    body.push(as_public.as_ref().len() as u8);
    body.extend_from_slice(as_public.as_ref());
    body.extend_from_slice(&record);
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::UnparsedPublicKey as VerifyKey;

    fn b64u(data: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(data)
    }

    #[test]
    fn endpoint_origin_extracts_authority() {
        assert_eq!(
            endpoint_origin("https://fcm.googleapis.com/fcm/send/abc").unwrap(),
            "https://fcm.googleapis.com"
        );
        assert_eq!(
            endpoint_origin("https://push.example.com:8443/x").unwrap(),
            "https://push.example.com:8443"
        );
        assert!(endpoint_origin("javascript:alert(1)").is_err());
        assert!(endpoint_origin("https:///x").is_err());
    }

    #[test]
    fn vapid_jwt_is_signed_and_has_expected_claims() {
        let keys = VapidKeys::generate().unwrap();
        let jwt = vapid_jwt("https://push.example.com/send/1", "mailto:a@b.c", &keys).unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);

        let header: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["typ"], "JWT");

        let claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["aud"], "https://push.example.com");
        assert_eq!(claims["sub"], "mailto:a@b.c");
        let exp = claims["exp"].as_i64().unwrap();
        let now = chrono::Utc::now().timestamp();
        assert!(exp > now && exp <= now + 24 * 60 * 60);

        // The signature verifies against the published public key.
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        assert_eq!(sig.len(), 64);
        let pubkey = VerifyKey::new(
            &ring::signature::ECDSA_P256_SHA256_FIXED,
            keys.public_key.as_slice(),
        );
        pubkey
            .verify(
                format!("{}.{}", parts[0], parts[1]).as_bytes(),
                sig.as_slice(),
            )
            .expect("jwt signature must verify");
    }

    /// Decrypt an aes128gcm body the way a user agent does: read the header,
    /// run ECDH with the embedded application-server public key, derive
    /// CEK/nonce, and open the single record.
    #[test]
    fn encrypt_payload_roundtrips_through_rfc8291_decryption() {
        let rng = ring::rand::SystemRandom::new();
        // Stand-in subscription: a fresh P-256 keypair + auth secret.
        let ua_private = EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
        let ua_public = ua_private.compute_public_key().unwrap();
        let auth = [9u8; 16];
        let payload = b"{\"title\":\"hello\"}";

        let body = encrypt_payload(&b64u(ua_public.as_ref()), &b64u(&auth), payload).unwrap();

        // Parse the aes128gcm header.
        let salt = &body[..16];
        let rs = u32::from_be_bytes(body[16..20].try_into().unwrap());
        let idlen = body[20] as usize;
        let as_public = &body[21..21 + idlen];
        let ciphertext = &body[21 + idlen..];
        assert!(rs as usize >= ciphertext.len());

        let peer = UnparsedPublicKey::new(&agreement::ECDH_P256, as_public);
        let shared = agreement::agree_ephemeral(ua_private, &peer, |s| s.to_vec()).unwrap();

        let mut info = b"WebPush: info\x00".to_vec();
        info.extend_from_slice(ua_public.as_ref());
        info.extend_from_slice(as_public);
        let ikm = hkdf_expand(&hkdf_extract(&auth, &shared), &info, 32).unwrap();
        let prk = hkdf_extract(salt, &ikm);
        let cek = hkdf_expand(&prk, b"Content-Encoding: aes128gcm\x00", 16).unwrap();
        let nonce_bytes = hkdf_expand(&prk, b"Content-Encoding: nonce\x00", 12).unwrap();

        let key = LessSafeKey::new(UnboundKey::new(&aead::AES_128_GCM, &cek).unwrap());
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&nonce_bytes);
        let mut buf = ciphertext.to_vec();
        let plain = key
            .open_in_place(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut buf)
            .expect("decrypt must succeed");
        // Trailing 0x02 marks the final record.
        assert_eq!(*plain.last().unwrap(), 0x02);
        assert_eq!(&plain[..plain.len() - 1], payload);
    }

    #[test]
    fn encrypt_payload_rejects_bad_keys() {
        assert!(encrypt_payload(&b64u(&[1, 2, 3]), &b64u(&[9u8; 16]), b"x").is_err());
        assert!(encrypt_payload("!!!", &b64u(&[9u8; 16]), b"x").is_err());
    }
}
