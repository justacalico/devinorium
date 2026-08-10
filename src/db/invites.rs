//! Invite token data access.

use chrono::{Duration, Utc};

impl super::Db {
    pub async fn create_invite(&self, created_by: i64, ttl_days: i64) -> anyhow::Result<String> {
        let token = crate::auth::tokens::random_token(24);
        let expires = Utc::now() + Duration::days(ttl_days);
        sqlx::query(
            "INSERT INTO invite_tokens (token, created_by_user_id, expires_at) VALUES (?, ?, ?)",
        )
        .bind(&token)
        .bind(created_by)
        .bind(expires.to_rfc3339())
        .execute(self.pool())
        .await?;
        Ok(token)
    }

    /// Returns Some(created_by_user_id) if the token is valid and unused.
    pub async fn validate_invite(&self, token: &str) -> anyhow::Result<Option<i64>> {
        let row: Option<(i64, Option<i64>, String)> = sqlx::query_as(
            "SELECT created_by_user_id, used_by_user_id, expires_at FROM invite_tokens WHERE token = ?",
        )
        .bind(token)
        .fetch_optional(self.pool())
        .await?;

        let Some((created_by, used_by, expires)) = row else {
            return Ok(None);
        };
        if used_by.is_some() {
            return Ok(None);
        }
        if super::parse_ts(&expires) <= Utc::now() {
            return Ok(None);
        }
        Ok(Some(created_by))
    }

    pub async fn consume_invite(&self, token: &str, user_id: i64) -> anyhow::Result<()> {
        sqlx::query("UPDATE invite_tokens SET used_by_user_id = ?, used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE token = ? AND used_by_user_id IS NULL")
            .bind(user_id)
            .bind(token)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn list_invites(&self) -> anyhow::Result<Vec<InviteRow>> {
        sqlx::query_as::<_, InviteRow>(
            "SELECT token, created_by_user_id, created_at, used_by_user_id, used_at, expires_at FROM invite_tokens ORDER BY created_at DESC",
        )
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }
}

#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct InviteRow {
    pub token: String,
    pub created_by_user_id: i64,
    pub created_at: String,
    pub used_by_user_id: Option<i64>,
    pub used_at: Option<String>,
    pub expires_at: String,
}
