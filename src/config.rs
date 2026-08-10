//! Application configuration loaded from environment variables.

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

/// All runtime configuration for a Devinorium instance.
#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub session_key: Vec<u8>,
    pub db_url: String,
    pub bootstrap_username: String,
    pub bootstrap_password: String,
    pub workspace_roots: Vec<PathBuf>,
    pub devin_bin: String,
    pub default_model: String,
    pub trust_proxy: bool,
    pub max_body_bytes: usize,
    pub secure_cookie: bool,
}

impl Config {
    /// Load configuration from environment variables, validating critical fields.
    pub fn from_env() -> Result<Self> {
        let host = env_or("DEVINORIUM_HOST", "127.0.0.1");
        let port = env_or("DEVINORIUM_PORT", "7878")
            .parse::<u16>()
            .context("DEVINORIUM_PORT must be a valid u16")?;

        let session_key_str = env::var("DEVINORIUM_SESSION_KEY").unwrap_or_default();
        let session_key = if session_key_str.is_empty() || session_key_str == "change-me-to-a-long-random-secret-please-64-chars-min" {
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
        let bootstrap_password =
            env::var("DEVINORIUM_BOOTSTRAP_PASSWORD").unwrap_or_default();
        if bootstrap_password.is_empty() || bootstrap_password == "change-me-to-a-strong-password" {
            tracing::warn!("DEVINORIUM_BOOTSTRAP_PASSWORD is not set to a real password; bootstrap account creation will be skipped. Set it to create the first user.");
        }

        let workspace_roots = env::var("DEVINORIUM_WORKSPACE_ROOTS")
            .unwrap_or_default()
            .split(',')
            .filter(|s| !s.trim().is_empty())
            .map(|s| PathBuf::from(s.trim()))
            .collect();

        let devin_bin = env_or("DEVINORIUM_DEVIN_BIN", "devin");
        let default_model = env_or("DEVINORIUM_DEFAULT_MODEL", "glm-5-2");
        let trust_proxy = env_or("DEVINORIUM_TRUST_PROXY", "false").eq_ignore_ascii_case("true");
        let max_body_bytes = env_or("DEVINORIUM_MAX_BODY_BYTES", "16777216")
            .parse::<usize>()
            .context("DEVINORIUM_MAX_BODY_BYTES must be a valid usize")?;
        let secure_cookie = env_or("DEVINORIUM_SECURE_COOKIE", "false").eq_ignore_ascii_case("true");

        Ok(Self {
            host,
            port,
            session_key,
            db_url,
            bootstrap_username,
            bootstrap_password,
            workspace_roots,
            devin_bin,
            default_model,
            trust_proxy,
            max_body_bytes,
            secure_cookie,
        })
    }

    /// The bind address (`host:port`).
    pub fn bind_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn rand_key(n: usize) -> Vec<u8> {
    use rand::RngCore;
    let mut buf = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut buf);
    buf
}
