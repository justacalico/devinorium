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

    pub async fn set_provider(
        &self,
        user_id: i64,
        provider_id: &str,
        provider_command: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE users SET provider_id = ?, provider_command = ? WHERE id = ?",
        )
        .bind(provider_id)
        .bind(provider_command)
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
}

#[allow(dead_code)]
fn _ensure_pool_used(_: &SqlitePool) {}
