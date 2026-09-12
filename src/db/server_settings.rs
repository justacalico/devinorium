//! Instance-level server settings.
//!
//! A single key/value table backs owner-managed options that must persist
//! across restarts (Tailscale serve, its HTTPS port). Values are stored as
//! text and parsed by callers.

const TAILSCALE_SERVE_KEY: &str = "tailscale_serve";
const TAILSCALE_SERVE_PORT_KEY: &str = "tailscale_serve_port";

async fn upsert_setting<'e>(
    executor: impl sqlx::SqliteExecutor<'e>,
    key: &str,
    value: &str,
) -> anyhow::Result<()> {
    sqlx::query("INSERT INTO server_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .bind(key)
        .bind(value)
        .execute(executor)
        .await?;
    Ok(())
}

impl super::Db {
    pub async fn get_server_setting(&self, key: &str) -> anyhow::Result<Option<String>> {
        let row: Option<(String,)> =
            sqlx::query_as("SELECT value FROM server_settings WHERE key = ?")
                .bind(key)
                .fetch_optional(self.pool())
                .await?;
        Ok(row.map(|r| r.0))
    }

    pub async fn set_server_setting(&self, key: &str, value: &str) -> anyhow::Result<()> {
        upsert_setting(self.pool(), key, value).await
    }

    /// The persisted Tailscale serve preference: whether the owner wants the
    /// mapping up and which tailnet HTTPS port to request when creating it.
    pub async fn get_tailscale_serve(&self) -> anyhow::Result<(bool, u16)> {
        let enabled = self
            .get_server_setting(TAILSCALE_SERVE_KEY)
            .await?
            .map(|v| v == "1")
            .unwrap_or(false);
        let port = self
            .get_server_setting(TAILSCALE_SERVE_PORT_KEY)
            .await?
            .and_then(|v| v.parse::<u16>().ok())
            .filter(|p| *p > 0)
            .unwrap_or(crate::tailscale::DEFAULT_SERVE_PORT);
        Ok((enabled, port))
    }

    /// Store the desired serve state; `port` is only written when given so a
    /// disable does not forget the configured port. Both keys land in one
    /// transaction so a crash cannot persist enabled with a stale port.
    pub async fn set_tailscale_serve(
        &self,
        enabled: bool,
        port: Option<u16>,
    ) -> anyhow::Result<()> {
        let mut tx = self.pool().begin().await?;
        upsert_setting(
            &mut *tx,
            TAILSCALE_SERVE_KEY,
            if enabled { "1" } else { "0" },
        )
        .await?;
        if let Some(port) = port {
            upsert_setting(&mut *tx, TAILSCALE_SERVE_PORT_KEY, &port.to_string()).await?;
        }
        tx.commit().await?;
        Ok(())
    }
}
