//! Federated satellite nodes registered with this hub.
//!
//! Rows are written by the registration endpoint when a satellite
//! announces itself, and refreshed on every heartbeat. `base_url` is how
//! the hub reaches the node for proxied requests; it is never shown to
//! non-owner users.

/// A row from the `federation_nodes` table.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct FederationNodeRow {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub version: String,
    pub last_seen_at: String,
    pub created_at: String,
}

impl super::Db {
    /// Insert a node or refresh an existing registration. Re-registering
    /// updates the name, address, version, and heartbeat time so a node
    /// that moved to a new address heals itself.
    pub async fn upsert_federation_node(
        &self,
        id: &str,
        name: &str,
        base_url: &str,
        version: &str,
    ) -> anyhow::Result<FederationNodeRow> {
        let row = sqlx::query_as::<_, FederationNodeRow>(
            "INSERT INTO federation_nodes (id, name, base_url, version, last_seen_at)
             VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
             ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 base_url = excluded.base_url,
                 version = excluded.version,
                 last_seen_at = excluded.last_seen_at
             RETURNING id, name, base_url, version, last_seen_at, created_at",
        )
        .bind(id)
        .bind(name)
        .bind(base_url)
        .bind(version)
        .fetch_one(self.pool())
        .await?;
        Ok(row)
    }

    pub async fn list_federation_nodes(&self) -> anyhow::Result<Vec<FederationNodeRow>> {
        let rows = sqlx::query_as::<_, FederationNodeRow>(
            "SELECT id, name, base_url, version, last_seen_at, created_at
             FROM federation_nodes ORDER BY name COLLATE NOCASE, id",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows)
    }

    pub async fn get_federation_node(&self, id: &str) -> anyhow::Result<Option<FederationNodeRow>> {
        let row = sqlx::query_as::<_, FederationNodeRow>(
            "SELECT id, name, base_url, version, last_seen_at, created_at
             FROM federation_nodes WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    pub async fn delete_federation_node(&self, id: &str) -> anyhow::Result<bool> {
        let res = sqlx::query("DELETE FROM federation_nodes WHERE id = ?")
            .bind(id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
    }
}

#[cfg(test)]
mod tests {
    use crate::db::Db;

    async fn db() -> Db {
        Db::connect("sqlite::memory:").await.unwrap()
    }

    #[tokio::test]
    async fn federation_node_roundtrip() {
        let db = db().await;
        let n = db
            .upsert_federation_node("id-1", "box", "http://10.0.0.2:7878", "0.1.0")
            .await
            .unwrap();
        assert_eq!(n.name, "box");
        assert_eq!(n.base_url, "http://10.0.0.2:7878");

        let listed = db.list_federation_nodes().await.unwrap();
        assert_eq!(listed.len(), 1);

        // Re-registering keeps the row and refreshes the address.
        let n2 = db
            .upsert_federation_node("id-1", "box2", "http://10.0.0.9:7878", "0.2.0")
            .await
            .unwrap();
        assert_eq!(n2.name, "box2");
        assert_eq!(n2.base_url, "http://10.0.0.9:7878");
        assert_eq!(n2.version, "0.2.0");
        assert_eq!(n2.created_at, n.created_at);
        assert_eq!(db.list_federation_nodes().await.unwrap().len(), 1);

        assert!(db.get_federation_node("id-1").await.unwrap().is_some());
        assert!(db.delete_federation_node("id-1").await.unwrap());
        assert!(db.get_federation_node("id-1").await.unwrap().is_none());
        assert!(!db.delete_federation_node("id-1").await.unwrap());
    }

    #[tokio::test]
    async fn list_federation_nodes_orders_by_name() {
        let db = db().await;
        db.upsert_federation_node("a", "zeta", "http://a", "")
            .await
            .unwrap();
        db.upsert_federation_node("b", "Alpha", "http://b", "")
            .await
            .unwrap();
        let names: Vec<String> = db
            .list_federation_nodes()
            .await
            .unwrap()
            .into_iter()
            .map(|n| n.name)
            .collect();
        assert_eq!(names, ["Alpha", "zeta"]);
    }
}
