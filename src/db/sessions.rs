//! Session data access (server-side session tokens).

use chrono::{Duration, Utc};

use super::SessionRow;

impl super::Db {
    pub async fn create_session(
        &self,
        user_id: i64,
        ttl_days: i64,
        ip_hash: Option<&str>,
        name: Option<&str>,
    ) -> anyhow::Result<SessionRow> {
        let token = crate::auth::tokens::random_token(32);
        let device_id = crate::auth::tokens::random_alnum(16);
        let now = Utc::now();
        let expires = now + Duration::days(ttl_days);

        sqlx::query_as::<_, SessionRow>(
            "INSERT INTO sessions (token, device_id, user_id, expires_at, ip_hash, name)
             VALUES (?, ?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&token)
        .bind(&device_id)
        .bind(user_id)
        .bind(expires.to_rfc3339())
        .bind(ip_hash)
        .bind(name)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn get_session(&self, token: &str) -> anyhow::Result<Option<SessionRow>> {
        let row: Option<SessionRow> = sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions WHERE token = ? AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')",
        )
        .bind(token)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    pub async fn touch_session(&self, token: &str) -> anyhow::Result<()> {
        sqlx::query("UPDATE sessions SET last_seen_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE token = ?")
            .bind(token)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_session(&self, token: &str) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM sessions WHERE token = ?")
            .bind(token)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_user_sessions(&self, user_id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM sessions WHERE user_id = ?")
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_session_for_user(&self, token: &str, user_id: i64) -> anyhow::Result<bool> {
        let res = sqlx::query("DELETE FROM sessions WHERE token = ? AND user_id = ?")
            .bind(token)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn purge_expired_sessions(&self) -> anyhow::Result<u64> {
        let res = sqlx::query(
            "DELETE FROM sessions WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ','now')",
        )
        .execute(self.pool())
        .await?;
        Ok(res.rows_affected())
    }
}
