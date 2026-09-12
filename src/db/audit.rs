//! Audit log data access.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct AuditRow {
    pub id: i64,
    pub user_id: Option<i64>,
    /// Username of the acting user, resolved with a LEFT JOIN. Stays `None`
    /// for system events and for users deleted after the entry was written.
    pub username: Option<String>,
    pub action: String,
    pub detail: String,
    pub ip_hash: Option<String>,
    pub created_at: String,
}

impl super::Db {
    pub async fn audit(
        &self,
        user_id: Option<i64>,
        action: &str,
        detail: &serde_json::Value,
        ip_hash: Option<&str>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO audit_logs (user_id, action, detail, ip_hash) VALUES (?, ?, ?, ?)",
        )
        .bind(user_id)
        .bind(action)
        .bind(detail.to_string())
        .bind(ip_hash)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Newest entries first. `None` limit returns everything.
    pub async fn list_audit(
        &self,
        limit: Option<i64>,
        offset: i64,
    ) -> anyhow::Result<Vec<AuditRow>> {
        sqlx::query_as::<_, AuditRow>(
            "SELECT a.id, a.user_id, u.username, a.action, a.detail, a.ip_hash, a.created_at
             FROM audit_logs a
             LEFT JOIN users u ON u.id = a.user_id
             ORDER BY a.id DESC
             LIMIT ? OFFSET ?",
        )
        // SQLite treats LIMIT -1 as "no limit".
        .bind(limit.unwrap_or(-1))
        .bind(offset)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }
}
