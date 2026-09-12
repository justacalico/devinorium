//! Application configuration loaded from environment variables.

use std::env;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};

/// All runtime configuration for a Devinorium instance.
#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub session_key: Vec<u8>,
    pub db_url: String,
    pub bootstrap_username: String,
    pub bootstrap_password: String,
    pub home_dir: PathBuf,
    pub default_model: String,
    pub trust_proxy: bool,
    pub max_body_bytes: usize,
    pub secure_cookie: bool,
    pub allowed_origin: Option<String>,
    /// Fixed bearer token accepted as the passwordless `local` account.
    /// Set by the desktop app when it spawns the bundled server, so local
    /// requests never need a login while random processes still cannot call
    /// the API without knowing the token.
    pub local_token: Option<String>,
    /// `--dev`/`--local` mode: every request runs as the passwordless
    /// `local` account with no credentials at all, on a random port with a
    /// throwaway in-memory database.
    pub dev_mode: bool,
}

impl Config {
    /// Load configuration from environment variables, validating critical fields.
    pub fn from_env() -> Result<Self> {
        let host = env_or("DEVINORIUM_HOST", "127.0.0.1");
        let port = env_or("DEVINORIUM_PORT", "7878")
            .parse::<u16>()
            .context("DEVINORIUM_PORT must be a valid u16")?;

        let session_key_str = env::var("DEVINORIUM_SESSION_KEY").unwrap_or_default();
        let session_key = if session_key_str.is_empty()
            || session_key_str == "change-me-to-a-long-random-secret-please-64-chars-min"
        {
            // Generate an ephemeral key for local dev. Warn the user.
            tracing::warn!("DEVINORIUM_SESSION_KEY not set; generating an ephemeral key. Sessions will not survive restarts. Set a permanent key for production.");
            rand_key(48)
        } else {
            // Derive a fixed-length key via simple SHA-256-like reduction is overkill;
            // we just use the raw bytes but require a minimum length.
            if session_key_str.len() < 32 {
                bail!("DEVINORIUM_SESSION_KEY must be at least 32 characters long");
            }
            session_key_str.into_bytes()
        };

        let db_url = env_or("DEVINORIUM_DB_URL", "sqlite:data/devinorium.db?mode=rwc");

        let bootstrap_username = env_or("DEVINORIUM_BOOTSTRAP_USERNAME", "owner");
        let bootstrap_password = env::var("DEVINORIUM_BOOTSTRAP_PASSWORD").unwrap_or_default();
        if bootstrap_password.is_empty() || bootstrap_password == "change-me-to-a-strong-password" {
            tracing::warn!("DEVINORIUM_BOOTSTRAP_PASSWORD is not set to a real password; bootstrap account creation will be skipped. Set it to create the first user.");
        }

        let home_dir = default_home_dir()
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

        let default_model = env_or("DEVINORIUM_DEFAULT_MODEL", "glm-5-2");
        let trust_proxy = env_or("DEVINORIUM_TRUST_PROXY", "false").eq_ignore_ascii_case("true");
        let max_body_bytes = env_or("DEVINORIUM_MAX_BODY_BYTES", "16777216")
            .parse::<usize>()
            .context("DEVINORIUM_MAX_BODY_BYTES must be a valid usize")?;
        let secure_cookie =
            env_or("DEVINORIUM_SECURE_COOKIE", "false").eq_ignore_ascii_case("true");
        let allowed_origin = std::env::var("DEVINORIUM_ALLOWED_ORIGIN")
            .ok()
            .filter(|s| !s.is_empty());

        let local_token = std::env::var("DEVINORIUM_LOCAL_TOKEN")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());

        Ok(Self {
            host,
            port,
            session_key,
            db_url,
            bootstrap_username,
            bootstrap_password,
            home_dir,
            default_model,
            trust_proxy,
            max_body_bytes,
            secure_cookie,
            allowed_origin,
            local_token,
            dev_mode: false,
        })
    }

    /// Switch into `--dev` mode: bind a random OS-assigned port and use a
    /// throwaway in-memory database that vanishes when the process exits.
    ///
    /// Dev mode serves the API with no authentication. It binds all
    /// interfaces so the UI can be reached from another machine; pass
    /// `local_only` (`--local`) to confine it to loopback.
    pub fn apply_dev_mode(&mut self, local_only: bool) -> Result<()> {
        self.host = if local_only { "127.0.0.1" } else { "0.0.0.0" }.to_string();
        self.port = 0;
        self.db_url = "sqlite::memory:".to_string();
        // An explicit allowed origin would pin CSRF/CORS to one origin,
        // which breaks browser access to the random dev port.
        self.allowed_origin = None;
        self.dev_mode = true;
        Ok(())
    }

    /// Refuse to start when the passwordless bearer token would be bound to
    /// a non-loopback interface: every host that can reach it would get
    /// owner-level API access. Dev mode ignores the token entirely, so the
    /// check does not apply there.
    pub fn check_local_token_bind(&self) -> Result<()> {
        if !self.dev_mode && self.local_token.is_some() && !is_loopback_host(&self.host) {
            bail!(
                "DEVINORIUM_LOCAL_TOKEN requires DEVINORIUM_HOST to be a loopback \
                 address (got {:?}); refusing to start",
                self.host
            );
        }
        Ok(())
    }

    /// The bind address (`host:port`, with IPv6 hosts bracketed).
    pub fn bind_addr(&self) -> String {
        if self
            .host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_ipv6())
        {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    /// Whether the server runs in bundled local mode (fixed bearer token
    /// instead of interactive logins).
    pub fn is_local_mode(&self) -> bool {
        self.local_token.is_some()
    }
}

pub(crate) fn is_loopback_host(host: &str) -> bool {
    // Accept bracketed IPv6 too — `bind_addr` tolerates either form.
    let host = host.trim_start_matches('[').trim_end_matches(']');
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    host.parse::<std::net::IpAddr>()
        .map(|ip| ip.is_loopback())
        .unwrap_or(false)
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Parse the dev-mode CLI flags, returning `(dev_mode, local_only)`.
/// `--dev` (or `-dev`) enables dev mode on all interfaces; `--local` (or
/// `-local`) implies dev mode and confines it to loopback.
pub fn parse_dev_args<I, S>(args: I) -> (bool, bool)
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let mut dev_mode = false;
    let mut local_only = false;
    for arg in args {
        let arg = arg.as_ref();
        if arg == "--dev" || arg == "-dev" {
            dev_mode = true;
        } else if arg == "--local" || arg == "-local" {
            local_only = true;
        }
    }
    (dev_mode || local_only, local_only)
}

pub fn default_home_dir() -> Option<PathBuf> {
    // Prefer $HOME on Unix, $USERPROFILE on Windows.
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
}

fn rand_key(n: usize) -> Vec<u8> {
    use rand::RngCore;
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_detection_accepts_local_addresses() {
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("127.0.0.2"));
        assert!(is_loopback_host("::1"));
        assert!(is_loopback_host("localhost"));
        assert!(is_loopback_host("LOCALHOST"));
    }

    #[test]
    fn loopback_detection_rejects_remote_and_wildcard_addresses() {
        assert!(!is_loopback_host("0.0.0.0"));
        assert!(!is_loopback_host("::"));
        assert!(!is_loopback_host("192.168.1.10"));
        assert!(!is_loopback_host("example.com"));
        assert!(!is_loopback_host(""));
    }

    fn cfg_with(host: &str, token: Option<&str>, dev_mode: bool) -> Config {
        Config {
            host: host.into(),
            port: 7878,
            session_key: vec![0; 48],
            db_url: "sqlite::memory:".into(),
            bootstrap_username: "owner".into(),
            bootstrap_password: "x".into(),
            home_dir: PathBuf::from("."),
            default_model: "m".into(),
            trust_proxy: false,
            max_body_bytes: 1024,
            secure_cookie: false,
            allowed_origin: None,
            local_token: token.map(str::to_string),
            dev_mode,
        }
    }

    #[test]
    fn local_token_bind_check_rejects_public_host() {
        assert!(cfg_with("0.0.0.0", Some("tok"), false)
            .check_local_token_bind()
            .is_err());
    }

    #[test]
    fn local_token_bind_check_allows_loopback_dev_and_no_token() {
        assert!(cfg_with("127.0.0.1", Some("tok"), false)
            .check_local_token_bind()
            .is_ok());
        // Dev mode ignores the token, so a public bind is fine.
        assert!(cfg_with("0.0.0.0", Some("tok"), true)
            .check_local_token_bind()
            .is_ok());
        assert!(cfg_with("0.0.0.0", None, false)
            .check_local_token_bind()
            .is_ok());
    }

    #[test]
    fn dev_args_parse_flag_combinations() {
        let parse = |args: &[&str]| parse_dev_args(args.iter().copied());
        assert_eq!(parse(&[]), (false, false));
        assert_eq!(parse(&["--dev"]), (true, false));
        assert_eq!(parse(&["-dev"]), (true, false));
        assert_eq!(parse(&["--local"]), (true, true));
        assert_eq!(parse(&["-local"]), (true, true));
        assert_eq!(parse(&["--dev", "--local"]), (true, true));
        assert_eq!(parse(&["-dev", "-local"]), (true, true));
        assert_eq!(parse(&["--other"]), (false, false));
    }
}
