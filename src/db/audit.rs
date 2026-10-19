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

    /// Drop entries older than the retention window. Bound as a strftime
    /// modifier so the interval can never inject into the query.
    pub async fn prune_audit_logs(&self, retention_days: u32) -> anyhow::Result<u64> {
        let res = sqlx::query(
            "DELETE FROM audit_logs
             WHERE created_at < strftime('%Y-%m-%dT%H:%M:%fZ','now', ?)",
        )
        .bind(format!("-{retention_days} days"))
        .execute(self.pool())
        .await?;
        Ok(res.rows_affected())
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

#[cfg(test)]
mod tests {
    use crate::db::Db;

    async fn db() -> Db {
        Db::connect("sqlite::memory:").await.unwrap()
    }

    #[tokio::test]
    async fn prune_removes_old_entries_and_keeps_recent() {
        let db = db().await;
        db.audit(None, "old", &serde_json::json!({}), None)
            .await
            .unwrap();
        db.audit(None, "fresh", &serde_json::json!({}), None)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE audit_logs SET created_at = '2000-01-01T00:00:00.000Z' WHERE action = 'old'",
        )
        .execute(db.pool())
        .await
        .unwrap();

        let removed = db.prune_audit_logs(90).await.unwrap();
        assert_eq!(removed, 1);

        let rows = db.list_audit(None, 0).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].action, "fresh");
    }

    #[tokio::test]
    async fn prune_with_zero_days_removes_everything_before_now() {
        let db = db().await;
        db.audit(None, "a", &serde_json::json!({}), None)
            .await
            .unwrap();
        sqlx::query("UPDATE audit_logs SET created_at = '2000-01-01T00:00:00.000Z'")
            .execute(db.pool())
            .await
            .unwrap();

        assert_eq!(db.prune_audit_logs(0).await.unwrap(), 1);
        assert!(db.list_audit(None, 0).await.unwrap().is_empty());
    }
}
