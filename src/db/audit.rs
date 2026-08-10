//! Audit log data access.

use serde::Serialize;

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct AuditRow {
    pub id: i64,
    pub user_id: Option<i64>,
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

    pub async fn list_audit(&self, limit: i64) -> anyhow::Result<Vec<AuditRow>> {
        sqlx::query_as::<_, AuditRow>(
            "SELECT * FROM audit_logs ORDER BY id DESC LIMIT ?",
        )
        .bind(limit)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }
}
