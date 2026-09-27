//! Minimal SSH client used by the machine-control endpoints.
//!
//! Each control call opens a short-lived connection: handshake, password
//! or public-key auth, then one `exec` per call collecting stdout/stderr
//! and the exit status. Host keys are pinned trust-on-first-use: callers
//! persist the fingerprint seen on the first successful probe and every
//! later connection must present the same key, before any credential
//! leaves the box.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{bail, Context};
use russh::client::{self, Handle, Handler};
use russh::keys::{decode_secret_key, PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::ChannelMsg;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Output collected per stream before truncation; a runaway remote
/// command cannot grow the response without bound.
pub const MAX_OUTPUT: usize = 512 * 1024;

/// Host-key check: accept and record the key when nothing is pinned yet
/// (TOFU), reject a mismatch so credentials never reach a different
/// server than the one the owner first probed.
struct PinnedHostKey {
    expected: Option<String>,
    observed: Arc<Mutex<Option<String>>>,
}

impl Handler for PinnedHostKey {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let fp = host_key_fingerprint(key);
        *self.observed.lock().unwrap_or_else(|e| e.into_inner()) = Some(fp.clone());
        Ok(match &self.expected {
            Some(expected) => expected == &fp,
            None => true,
        })
    }
}

/// `SHA256:<base64>` over the presented host key — same shape OpenSSH
/// prints, so the stored value is recognizable and comparable by hand.
fn host_key_fingerprint(key: &PublicKeyOrCertificate) -> String {
    match key {
        PublicKeyOrCertificate::PublicKey { key, .. } => {
            key.fingerprint(russh::keys::HashAlg::Sha256).to_string()
        }
        // Pin the subject key, not the cert blob: a host-cert renewal
        // must not look like a key change.
        PublicKeyOrCertificate::Certificate(cert) => cert
            .public_key()
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string(),
    }
}

/// One `exec` round: the exit status or signal (absent when the server
/// closed the channel without reporting either) and the collected
/// streams.
#[derive(Debug, Default)]
pub struct ExecOutput {
    pub code: Option<u32>,
    /// Signal name when the remote process was killed (`TERM`, `KILL`).
    pub signal: Option<String>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// True when a stream hit [`MAX_OUTPUT`] and bytes were dropped.
    pub truncated: bool,
}

pub struct SshSession {
    handle: Handle<PinnedHostKey>,
    /// Fingerprint of the host key this session negotiated with.
    pub fingerprint: String,
}

impl SshSession {
    /// Connect and authenticate. When `expected_fingerprint` is empty the
    /// presented host key is trusted on first use and echoed back in
    /// `fingerprint` for the caller to pin; when it is set a different key
    /// aborts the handshake before credentials are sent. A non-empty
    /// `key_pem` tries public-key auth first (with `password` as the
    /// optional key passphrase) and falls back to password auth when the
    /// key cannot be decoded or is rejected.
    pub async fn connect(
        host: &str,
        port: u16,
        user: &str,
        password: &str,
        key_pem: &str,
        expected_fingerprint: &str,
    ) -> anyhow::Result<Self> {
        let expected = (!expected_fingerprint.is_empty()).then(|| expected_fingerprint.to_string());
        let observed = Arc::new(Mutex::new(None::<String>));
        let config = Arc::new(client::Config {
            // No inactivity timeout: callers wrap the whole call in their
            // own deadline, and a quiet remote command must not be cut
            // off mid-run.
            inactivity_timeout: None,
            ..Default::default()
        });
        let handler = PinnedHostKey {
            expected: expected.clone(),
            observed: observed.clone(),
        };
        let mut handle = tokio::time::timeout(
            CONNECT_TIMEOUT,
            client::connect(config, (host, port), handler),
        )
        .await
        .with_context(|| format!("connecting to {host}:{port} timed out"))?
        .map_err(|e| {
            if expected.is_some() && matches!(e, russh::Error::UnknownKey) {
                let seen = observed
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .clone()
                    .unwrap_or_default();
                anyhow::anyhow!(
                    "ssh host key changed (expected {expected_fingerprint}, \
                     got {seen}); edit the machine to re-pin"
                )
            } else {
                anyhow::Error::new(e).context(format!("connecting to {host}:{port}"))
            }
        })?;
        let fingerprint = observed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
            .unwrap_or_default();

        let mut authenticated = false;
        if !key_pem.is_empty() {
            let passphrase = (!password.is_empty()).then_some(password);
            match decode_secret_key(key_pem, passphrase) {
                Ok(key) => {
                    let key: PrivateKey = key;
                    let hash = handle
                        .best_supported_rsa_hash()
                        .await
                        .ok()
                        .flatten()
                        .flatten();
                    authenticated = handle
                        .authenticate_publickey(
                            user,
                            PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                        )
                        .await
                        .context("ssh public-key authentication failed")?
                        .success();
                }
                // A corrupt key falls through to password auth rather
                // than bricking a machine that has a valid password.
                Err(e) if password.is_empty() => return Err(e).context("invalid private key"),
                Err(_) => {}
            }
        }
        // Skip the attempt entirely with no password: a doomed guess
        // still counts toward server-side lockouts (MaxAuthTries).
        if !authenticated && !password.is_empty() {
            authenticated = handle
                .authenticate_password(user, password)
                .await
                .context("ssh password authentication failed")?
                .success();
        }
        if !authenticated {
            bail!("ssh authentication failed for {user}@{host}:{port}");
        }
        Ok(Self {
            handle,
            fingerprint,
        })
    }

    /// Run `command` on a fresh session channel and collect its output.
    /// Returns after the channel closes; a server that rejects the exec
    /// request (forced-command accounts, restricted shells) surfaces as
    /// an error instead of an empty success.
    pub async fn exec(&mut self, command: &str) -> anyhow::Result<ExecOutput> {
        let mut channel = self.handle.channel_open_session().await?;
        channel
            .exec(true, command)
            .await
            .context("ssh exec request failed")?;

        let mut out = ExecOutput::default();
        while let Some(msg) = channel.wait().await {
            match msg {
                ChannelMsg::Data { data } => {
                    push_capped(&mut out.stdout, &data, &mut out.truncated);
                }
                ChannelMsg::ExtendedData { data, ext: 1 } => {
                    push_capped(&mut out.stderr, &data, &mut out.truncated);
                }
                ChannelMsg::ExitStatus { exit_status } => {
                    out.code = Some(exit_status);
                }
                ChannelMsg::ExitSignal { signal_name, .. } => {
                    out.signal = Some(sig_name(&signal_name));
                }
                ChannelMsg::Failure => {
                    bail!("ssh server rejected the exec request");
                }
                _ => {}
            }
        }
        Ok(out)
    }

    pub async fn disconnect(&mut self) {
        let _ = self
            .handle
            .disconnect(russh::Disconnect::ByApplication, "", "en")
            .await;
    }
}

/// `Sig` keeps its name accessor private; map the standard signals and
/// fall back to the Debug form for custom ones.
fn sig_name(sig: &russh::Sig) -> String {
    use russh::Sig;
    match sig {
        Sig::ABRT => "ABRT".into(),
        Sig::ALRM => "ALRM".into(),
        Sig::FPE => "FPE".into(),
        Sig::HUP => "HUP".into(),
        Sig::ILL => "ILL".into(),
        Sig::INT => "INT".into(),
        Sig::KILL => "KILL".into(),
        Sig::PIPE => "PIPE".into(),
        Sig::QUIT => "QUIT".into(),
        Sig::SEGV => "SEGV".into(),
        Sig::TERM => "TERM".into(),
        Sig::USR1 => "USR1".into(),
        other => format!("{other:?}"),
    }
}

fn push_capped(buf: &mut Vec<u8>, data: &[u8], truncated: &mut bool) {
    let room = MAX_OUTPUT.saturating_sub(buf.len());
    if data.len() <= room {
        buf.extend_from_slice(data);
    } else {
        buf.extend_from_slice(&data[..room]);
        *truncated = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_capped_truncates_past_the_cap() {
        let mut buf = Vec::new();
        let mut truncated = false;
        push_capped(&mut buf, &[1u8; 16], &mut truncated);
        assert_eq!(buf.len(), 16);
        assert!(!truncated);
        push_capped(&mut buf, &[2u8; MAX_OUTPUT], &mut truncated);
        assert_eq!(buf.len(), MAX_OUTPUT);
        assert!(truncated);
    }
}
