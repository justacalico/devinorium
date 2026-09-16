//! Server-wide VNC machines.
//!
//! Machines are shared by every account on the instance: any signed-in
//! user may reference them in a thread, only the owner changes the list.
//! `password` holds the VNC auth secret; API responses expose
//! `has_password` instead.

/// A row from the `machines` table.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct MachineRow {
    pub id: i64,
    pub name: String,
    pub host: String,
    pub port: i64,
    #[serde(skip_serializing)]
    pub password: String,
    pub created_at: String,
    pub updated_at: String,
}

impl super::Db {
    pub async fn list_machines(&self) -> anyhow::Result<Vec<MachineRow>> {
        let rows = sqlx::query_as::<_, MachineRow>(
            "SELECT id, name, host, port, password, created_at, updated_at
             FROM machines ORDER BY name COLLATE NOCASE, id",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows)
    }

    pub async fn get_machine(&self, id: i64) -> anyhow::Result<Option<MachineRow>> {
        let row = sqlx::query_as::<_, MachineRow>(
            "SELECT id, name, host, port, password, created_at, updated_at
             FROM machines WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    pub async fn create_machine(
        &self,
        name: &str,
        host: &str,
        port: i64,
        password: &str,
    ) -> anyhow::Result<MachineRow> {
        let row = sqlx::query_as::<_, MachineRow>(
            "INSERT INTO machines (name, host, port, password)
             VALUES (?, ?, ?, ?)
             RETURNING id, name, host, port, password, created_at, updated_at",
        )
        .bind(name)
        .bind(host)
        .bind(port)
        .bind(password)
        .fetch_one(self.pool())
        .await?;
        Ok(row)
    }

    /// Patch a machine. `password` distinguishes absent (keep the stored
    /// secret) from present (replace, including with the empty string).
    pub async fn update_machine(
        &self,
        id: i64,
        name: Option<&str>,
        host: Option<&str>,
        port: Option<i64>,
        password: Option<&str>,
    ) -> anyhow::Result<Option<MachineRow>> {
        let row = sqlx::query_as::<_, MachineRow>(
            "UPDATE machines SET
                 name = COALESCE(?, name),
                 host = COALESCE(?, host),
                 port = COALESCE(?, port),
                 password = COALESCE(?, password),
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE id = ?
             RETURNING id, name, host, port, password, created_at, updated_at",
        )
        .bind(name)
        .bind(host)
        .bind(port)
        .bind(password)
        .bind(id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    pub async fn delete_machine(&self, id: i64) -> anyhow::Result<bool> {
        let res = sqlx::query("DELETE FROM machines WHERE id = ?")
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
    async fn machine_crud_roundtrip() {
        let db = db().await;
        let m = db
            .create_machine("desktop", "192.168.1.10", 5900, "secret")
            .await
            .unwrap();
        assert_eq!(m.name, "desktop");
        assert_eq!(m.port, 5900);
        assert_eq!(m.password, "secret");

        let listed = db.list_machines().await.unwrap();
        assert_eq!(listed.len(), 1);

        let updated = db
            .update_machine(m.id, Some("renamed"), None, Some(5901), None)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.name, "renamed");
        assert_eq!(updated.host, "192.168.1.10");
        assert_eq!(updated.port, 5901);
        // Absent password keeps the stored secret.
        assert_eq!(updated.password, "secret");

        let cleared = db
            .update_machine(m.id, None, None, None, Some(""))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cleared.password, "");

        assert!(db.delete_machine(m.id).await.unwrap());
        assert!(db.get_machine(m.id).await.unwrap().is_none());
        assert!(!db.delete_machine(m.id).await.unwrap());
    }

    #[tokio::test]
    async fn list_machines_orders_by_name() {
        let db = db().await;
        db.create_machine("zeta", "h1", 5900, "").await.unwrap();
        db.create_machine("Alpha", "h2", 5900, "").await.unwrap();
        let names: Vec<String> = db
            .list_machines()
            .await
            .unwrap()
            .into_iter()
            .map(|m| m.name)
            .collect();
        assert_eq!(names, ["Alpha", "zeta"]);
    }
}
