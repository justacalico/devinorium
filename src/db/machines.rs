//! Server-wide machines an agent can remote-control.
//!
//! Machines are shared by every account on the instance: any signed-in
//! user may reference them in a thread, only the owner changes the list.
//! `kind` picks the protocol scope — `vnc` (screen control) or `ssh`
//! (remote shell). `password` holds the VNC auth secret or the SSH login
//! password/key passphrase, `ssh_key` a PEM private key; API responses
//! expose `has_password`/`has_ssh_key` instead of the secrets.

/// The protocol scope a machine entry grants.
pub const KIND_VNC: &str = "vnc";
pub const KIND_SSH: &str = "ssh";

/// A row from the `machines` table.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct MachineRow {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub host: String,
    pub port: i64,
    pub ssh_user: String,
    /// Host-key fingerprint pinned on first probe (TOFU); empty until seen.
    pub ssh_fingerprint: String,
    #[serde(skip_serializing)]
    pub password: String,
    #[serde(skip_serializing)]
    pub ssh_key: String,
    pub created_at: String,
    pub updated_at: String,
}

impl MachineRow {
    pub fn is_ssh(&self) -> bool {
        self.kind == KIND_SSH
    }
}

/// Fields every write path touches; optional fields distinguish absent
/// (keep the stored value) from present (replace, including empty).
#[derive(Debug, Default)]
pub struct MachineUpdate {
    pub name: Option<String>,
    pub kind: Option<String>,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub ssh_user: Option<String>,
    pub ssh_fingerprint: Option<String>,
    pub password: Option<String>,
    pub ssh_key: Option<String>,
}

impl super::Db {
    pub async fn list_machines(&self) -> anyhow::Result<Vec<MachineRow>> {
        let rows = sqlx::query_as::<_, MachineRow>(
            "SELECT id, name, kind, host, port, ssh_user, ssh_fingerprint, password,
                    ssh_key, created_at, updated_at
             FROM machines ORDER BY name COLLATE NOCASE, id
             LIMIT 1000",
        )
        .fetch_all(self.pool())
        .await?;
        Ok(rows)
    }

    pub async fn get_machine(&self, id: i64) -> anyhow::Result<Option<MachineRow>> {
        let row = sqlx::query_as::<_, MachineRow>(
            "SELECT id, name, kind, host, port, ssh_user, ssh_fingerprint, password,
                    ssh_key, created_at, updated_at
             FROM machines WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_machine(
        &self,
        name: &str,
        kind: &str,
        host: &str,
        port: i64,
        ssh_user: &str,
        password: &str,
        ssh_key: &str,
    ) -> anyhow::Result<MachineRow> {
        let row = sqlx::query_as::<_, MachineRow>(
            "INSERT INTO machines (name, kind, host, port, ssh_user, password, ssh_key)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             RETURNING id, name, kind, host, port, ssh_user, ssh_fingerprint,
                       password, ssh_key, created_at, updated_at",
        )
        .bind(name)
        .bind(kind)
        .bind(host)
        .bind(port)
        .bind(ssh_user)
        .bind(password)
        .bind(ssh_key)
        .fetch_one(self.pool())
        .await?;
        Ok(row)
    }

    /// Patch a machine. Absent fields keep their stored values, so a
    /// `None` secret never wipes the credential.
    pub async fn update_machine(
        &self,
        id: i64,
        patch: &MachineUpdate,
    ) -> anyhow::Result<Option<MachineRow>> {
        let row = sqlx::query_as::<_, MachineRow>(
            "UPDATE machines SET
                 name = COALESCE(?, name),
                 kind = COALESCE(?, kind),
                 host = COALESCE(?, host),
                 port = COALESCE(?, port),
                 ssh_user = COALESCE(?, ssh_user),
                 ssh_fingerprint = COALESCE(?, ssh_fingerprint),
                 password = COALESCE(?, password),
                 ssh_key = COALESCE(?, ssh_key),
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE id = ?
             RETURNING id, name, kind, host, port, ssh_user, ssh_fingerprint,
                       password, ssh_key, created_at, updated_at",
        )
        .bind(patch.name.as_deref())
        .bind(patch.kind.as_deref())
        .bind(patch.host.as_deref())
        .bind(patch.port)
        .bind(patch.ssh_user.as_deref())
        .bind(patch.ssh_fingerprint.as_deref())
        .bind(patch.password.as_deref())
        .bind(patch.ssh_key.as_deref())
        .bind(id)
        .fetch_optional(self.pool())
        .await?;
        Ok(row)
    }

    /// Pin a freshly seen host-key fingerprint. Only fills an empty slot —
    /// a concurrent write or a rotated key is never silently overwritten.
    pub async fn pin_machine_fingerprint(&self, id: i64, fp: &str) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE machines SET ssh_fingerprint = ? WHERE id = ? AND ssh_fingerprint = ''",
        )
        .bind(fp)
        .bind(id)
        .execute(self.pool())
        .await?;
        Ok(())
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
    use super::*;
    use crate::db::Db;

    async fn db() -> Db {
        Db::connect("sqlite::memory:").await.unwrap()
    }

    #[tokio::test]
    async fn machine_crud_roundtrip() {
        let db = db().await;
        let m = db
            .create_machine("desktop", KIND_VNC, "192.168.1.10", 5900, "", "secret", "")
            .await
            .unwrap();
        assert_eq!(m.name, "desktop");
        assert_eq!(m.kind, KIND_VNC);
        assert!(!m.is_ssh());
        assert_eq!(m.port, 5900);
        assert_eq!(m.password, "secret");

        let listed = db.list_machines().await.unwrap();
        assert_eq!(listed.len(), 1);

        let updated = db
            .update_machine(
                m.id,
                &MachineUpdate {
                    name: Some("renamed".into()),
                    port: Some(5901),
                    ..Default::default()
                },
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.name, "renamed");
        assert_eq!(updated.host, "192.168.1.10");
        assert_eq!(updated.port, 5901);
        // Absent password keeps the stored secret.
        assert_eq!(updated.password, "secret");

        let cleared = db
            .update_machine(
                m.id,
                &MachineUpdate {
                    password: Some(String::new()),
                    ..Default::default()
                },
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(cleared.password, "");

        assert!(db.delete_machine(m.id).await.unwrap());
        assert!(db.get_machine(m.id).await.unwrap().is_none());
        assert!(!db.delete_machine(m.id).await.unwrap());
    }

    #[tokio::test]
    async fn ssh_machine_roundtrip() {
        let db = db().await;
        let m = db
            .create_machine("box", KIND_SSH, "10.0.0.5", 22, "root", "pw", "PRIVATE KEY")
            .await
            .unwrap();
        assert!(m.is_ssh());
        assert_eq!(m.ssh_user, "root");
        assert_eq!(m.ssh_key, "PRIVATE KEY");

        let updated = db
            .update_machine(
                m.id,
                &MachineUpdate {
                    kind: Some(KIND_VNC.into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(updated.kind, KIND_VNC);
        // Changing scope keeps the ssh fields; the API decides what is
        // meaningful per kind, the row just stores them.
        assert_eq!(updated.ssh_user, "root");
    }

    #[tokio::test]
    async fn invalid_kind_is_rejected() {
        let db = db().await;
        let err = db
            .create_machine("m", "rdp", "h", 3389, "", "", "")
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("invalid machine kind"));
    }

    #[tokio::test]
    async fn list_machines_orders_by_name() {
        let db = db().await;
        db.create_machine("zeta", KIND_VNC, "h1", 5900, "", "", "")
            .await
            .unwrap();
        db.create_machine("Alpha", KIND_VNC, "h2", 5900, "", "", "")
            .await
            .unwrap();
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
