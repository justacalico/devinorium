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
        self._create_session(user_id, ttl_days, ip_hash, name, None)
            .await
    }

    /// Create a new session, but only if the user is below [max_sessions].
    /// The check and insert are wrapped in a transaction to avoid races.
    pub async fn create_session_limited(
        &self,
        user_id: i64,
        ttl_days: i64,
        ip_hash: Option<&str>,
        name: Option<&str>,
        max_sessions: i64,
    ) -> anyhow::Result<SessionRow> {
        self._create_session(user_id, ttl_days, ip_hash, name, Some(max_sessions))
            .await
    }

    async fn _create_session(
        &self,
        user_id: i64,
        ttl_days: i64,
        ip_hash: Option<&str>,
        name: Option<&str>,
        max_sessions: Option<i64>,
    ) -> anyhow::Result<SessionRow> {
        let token = crate::auth::tokens::random_token(32);
        let device_id = crate::auth::tokens::random_alnum(16);
        let now = Utc::now();
        let expires = now + Duration::days(ttl_days);

        let mut tx = self.pool().begin().await?;

        if let Some(max) = max_sessions {
            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM sessions
                 WHERE user_id = ? AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')",
            )
            .bind(user_id)
            .fetch_one(&mut *tx)
            .await?;
            if count >= max {
                tx.rollback().await?;
                return Err(anyhow::anyhow!("too many paired devices"));
            }
        }

        let row: SessionRow = sqlx::query_as::<_, SessionRow>(
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
        .fetch_one(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(row)
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

    pub async fn list_user_sessions(&self, user_id: i64) -> anyhow::Result<Vec<SessionRow>> {
        sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions
             WHERE user_id = ? AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
             ORDER BY created_at DESC",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn delete_session_for_user(
        &self,
        token: &str,
        user_id: i64,
    ) -> anyhow::Result<bool> {
        let res = sqlx::query("DELETE FROM sessions WHERE token = ? AND user_id = ?")
            .bind(token)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn delete_session_by_device_id_for_user(
        &self,
        device_id: &str,
        user_id: i64,
    ) -> anyhow::Result<bool> {
        let res =
            sqlx::query("DELETE FROM sessions WHERE device_id = ? AND user_id = ?")
                .bind(device_id)
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
