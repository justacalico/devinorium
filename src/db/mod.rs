//! Database access layer (SQLite via sqlx).
//!
//! This module owns the connection pool, migrations, and all data-access
//! functions. Higher layers (auth, api) call into here and never touch SQL
//! directly.

use std::str::FromStr;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    Connection as _, SqliteConnection, SqlitePool,
};

pub mod audit;
pub mod messages;
pub mod plans;
pub mod projects;
pub mod sessions;
pub mod thread_groups;
pub mod threads;
pub mod users;

pub use messages::{DuplicateClientMessageId, NewMessage, MAX_CLIENT_MESSAGE_ID_LEN};
pub use plans::{NewPlan, PlanRow};
pub use projects::NewProject;
pub use thread_groups::NewThreadGroup;
pub use threads::NewThread;
pub use users::NewUser;

/// A typed handle to the SQLite pool plus app-wide db config.
#[derive(Clone)]
pub struct Db {
    pool: SqlitePool,
}

impl Db {
    /// Open the database, run migrations, and return a handle.
    pub async fn connect(url: &str) -> Result<Self> {
        let opts = SqliteConnectOptions::from_str(url)?
            .create_if_missing(true)
            .foreign_keys(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);

        // Open a one-off connection with a short busy timeout to verify no
        // other process is actively holding a write lock before we start.
        let probe_opts = opts
            .clone()
            .busy_timeout(Duration::from_millis(100))
            .read_only(false);
        let mut probe = SqliteConnection::connect_with(&probe_opts)
            .await
            .with_context(|| format!("connecting to sqlite at {url}"))?;
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut probe)
            .await
            .context("database is locked by another process; close any database viewers or other Devinorium instances before starting")?;
        sqlx::query("ROLLBACK").execute(&mut probe).await?;
        probe.close().await?;

        let pool = SqlitePoolOptions::new()
            .max_connections(8)
            .connect_with(opts)
            .await
            .with_context(|| format!("connecting to sqlite at {url}"))?;

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .context("running migrations")?;

        Ok(Self { pool })
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}

/// A row from the `users` table.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct UserRow {
    pub id: i64,
    pub username: String,
    pub password_hash: String,
    pub totp_secret: Option<String>,
    pub totp_enabled: bool,
    pub role: String,
    pub created_at: String,
    pub disabled: bool,
    pub is_owner: bool,
    pub clone_root: Option<String>,
    pub provider_id: String,
    pub provider_command: String,
    /// JSON object mapping provider id -> CLI command, e.g.
    /// `{"devin-cli": "devin", "opencode": "opencode"}`.
    pub provider_commands: String,
}

impl UserRow {
    /// Parse the per-provider command map. A corrupt value behaves as empty.
    pub fn provider_commands_map(&self) -> std::collections::HashMap<String, String> {
        serde_json::from_str(&self.provider_commands).unwrap_or_default()
    }

    /// The command configured for `provider_id`: the per-provider map first,
    /// then the legacy single-provider command for the default provider, then
    /// the built-in default. An empty result means "use the app-level
    /// provider" (only reachable in tests that inject a stub).
    pub fn command_for_provider(&self, provider_id: &str) -> String {
        if let Some(command) = self
            .provider_commands_map()
            .get(provider_id)
            .map(|c| c.trim())
            .filter(|c| !c.is_empty())
        {
            return command.to_string();
        }
        if provider_id == self.provider_id {
            return self.provider_command.trim().to_string();
        }
        crate::providers::default_command(provider_id).to_string()
    }
}

/// A row from the `sessions` table.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct SessionRow {
    pub token: String,
    pub device_id: String,
    pub user_id: i64,
    pub created_at: String,
    pub expires_at: String,
    pub last_seen_at: String,
    pub ip_hash: Option<String>,
    pub name: Option<String>,
}

/// A row from the `threads` table.
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct ThreadRow {
    pub id: String,
    pub user_id: i64,
    pub title: String,
    /// Provider-owned session id (named `devin_session_id` for historical
    /// reasons; it holds whatever the thread's provider returned).
    pub devin_session_id: Option<String>,
    /// The provider this thread runs on. Locked once a session exists.
    pub provider_id: String,
    pub model: String,
    pub permission_mode: String,
    pub permissions: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub thread_group_id: Option<i64>,
    pub project_id: Option<i64>,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    pub pinned: bool,
    pub title_user_set: bool,
}

/// A row from the `projects` table.
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct ProjectRow {
    pub id: i64,
    pub user_id: i64,
    pub name: String,
    pub path: String,
    pub position: i64,
    pub project_type: String,
    pub pinned: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// A row from the `messages` table.
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct MessageRow {
    pub id: i64,
    pub thread_id: String,
    pub role: String,
    pub content: String,
    pub thinking: Option<String>,
    pub parts: Option<String>,
    pub attachments: String,
    pub model: String,
    pub client_message_id: Option<String>,
    pub created_at: String,
    pub turn_id: i64,
    pub seq: i64,
    pub content_length: i64,
    pub parts_length: Option<i64>,
}

/// A row from the `thread_groups` table.
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct ThreadGroupRow {
    pub id: i64,
    pub user_id: i64,
    pub name: String,
    pub position: i64,
    pub created_at: String,
}
