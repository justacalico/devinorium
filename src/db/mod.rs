//! Database access layer (SQLite via sqlx).
//!
//! This module owns the connection pool, migrations, and all data-access
//! functions. Higher layers (auth, api) call into here and never touch SQL
//! directly.

use std::str::FromStr;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    SqlitePool,
};

pub mod audit;
pub mod messages;
pub mod projects;
pub mod sessions;
pub mod thread_groups;
pub mod threads;
pub mod users;

pub use projects::NewProject;
pub use messages::NewMessage;
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
    pub provider_id: String,
    pub provider_command: String,
}

/// A row from the `sessions` table.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct SessionRow {
    pub token: String,
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
    pub devin_session_id: Option<String>,
    pub model: String,
    pub permission_mode: String,
    pub permissions: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub thread_group_id: Option<i64>,
    pub project_id: Option<i64>,
}

/// A row from the `projects` table.
#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct ProjectRow {
    pub id: i64,
    pub user_id: i64,
    pub name: String,
    pub path: String,
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
    pub attachments: String,
    pub created_at: String,
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
