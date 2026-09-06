//! User data access.

use sqlx::SqlitePool;

use super::UserRow;

pub struct NewUser {
    pub username: String,
    pub password_hash: String,
    pub is_owner: bool,
}

impl super::Db {
    pub async fn create_user(&self, new: NewUser) -> anyhow::Result<UserRow> {
        sqlx::query_as::<_, UserRow>(
            "INSERT INTO users (username, password_hash, is_owner) VALUES (?, ?, ?)
             RETURNING *",
        )
        .bind(&new.username)
        .bind(&new.password_hash)
        .bind(new.is_owner)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn set_user_owner(&self, user_id: i64, is_owner: bool) -> anyhow::Result<()> {
        sqlx::query("UPDATE users SET is_owner = ? WHERE id = ?")
            .bind(is_owner)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// Apply provider settings in a single statement so the default provider,
    /// its legacy command column, and the per-provider command map can never
    /// end up half-updated. `commands_patch` is merged into
    /// `provider_commands` with `json_patch`; null values remove keys.
    pub async fn update_provider_settings(
        &self,
        user_id: i64,
        provider_id: Option<&str>,
        provider_command: Option<&str>,
        commands_patch: &serde_json::Map<String, serde_json::Value>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE users
             SET provider_id = COALESCE(?, provider_id),
                 provider_command = COALESCE(?, provider_command),
                 provider_commands = json_patch(provider_commands, ?)
             WHERE id = ?",
        )
        .bind(provider_id)
        .bind(provider_command)
        .bind(serde_json::Value::Object(commands_patch.clone()).to_string())
        .bind(user_id)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    pub async fn get_user_by_username(&self, username: &str) -> anyhow::Result<Option<UserRow>> {
        sqlx::query_as::<_, UserRow>("SELECT * FROM users WHERE username = ?")
            .bind(username)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_user_by_id(&self, id: i64) -> anyhow::Result<Option<UserRow>> {
        sqlx::query_as::<_, UserRow>("SELECT * FROM users WHERE id = ?")
            .bind(id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn count_users(&self) -> anyhow::Result<i64> {
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
            .fetch_one(self.pool())
            .await?;
        Ok(n)
    }

    pub async fn set_totp(
        &self,
        user_id: i64,
        secret: Option<String>,
        enabled: bool,
    ) -> anyhow::Result<()> {
        sqlx::query("UPDATE users SET totp_secret = ?, totp_enabled = ? WHERE id = ?")
            .bind(secret)
            .bind(enabled)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn set_user_disabled(&self, user_id: i64, disabled: bool) -> anyhow::Result<()> {
        sqlx::query("UPDATE users SET disabled = ? WHERE id = ?")
            .bind(disabled)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn list_users(&self) -> anyhow::Result<Vec<UserRow>> {
        sqlx::query_as::<_, UserRow>("SELECT * FROM users ORDER BY id")
            .fetch_all(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Return the clone root for this user, or the first owner if the caller
    /// is not an owner. Non-owner users can see where clones will land but
    /// cannot change it.
    pub async fn get_clone_root(&self, user_id: i64) -> anyhow::Result<Option<String>> {
        if let Some(user) = self.get_user_by_id(user_id).await? {
            if user.is_owner {
                return Ok(user.clone_root);
            }
        }
        let row: Option<(Option<String>,)> =
            sqlx::query_as("SELECT clone_root FROM users WHERE is_owner = 1 ORDER BY id LIMIT 1")
                .fetch_optional(self.pool())
                .await?;
        Ok(row.and_then(|r| r.0))
    }

    pub async fn set_clone_root(&self, user_id: i64, path: Option<&str>) -> anyhow::Result<()> {
        if let Some(user) = self.get_user_by_id(user_id).await? {
            if !user.is_owner {
                anyhow::bail!("only the owner can set the clone root");
            }
        } else {
            anyhow::bail!("user not found");
        }
        sqlx::query("UPDATE users SET clone_root = ? WHERE id = ?")
            .bind(path)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }
}

#[allow(dead_code)]
fn _ensure_pool_used(_: &SqlitePool) {}
