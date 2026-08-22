//! Thread group data access.

use super::ThreadGroupRow;

pub struct NewThreadGroup {
    pub user_id: i64,
    pub name: String,
    pub position: i64,
}

impl super::Db {
    pub async fn create_thread_group(&self, new: NewThreadGroup) -> anyhow::Result<ThreadGroupRow> {
        sqlx::query_as::<_, ThreadGroupRow>(
            "INSERT INTO thread_groups (user_id, name, position)
             VALUES (?, ?, ?)
             RETURNING *",
        )
        .bind(new.user_id)
        .bind(&new.name)
        .bind(new.position)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_thread_groups(
        &self,
        user_id: i64,
        limit: Option<i64>,
        offset: i64,
    ) -> anyhow::Result<Vec<ThreadGroupRow>> {
        let mut sql =
            "SELECT * FROM thread_groups WHERE user_id = ? ORDER BY position ASC, id ASC".to_string();
        if let Some(l) = limit {
            sql.push_str(&format!(" LIMIT {l} OFFSET {offset}"));
        }
        sqlx::query_as::<_, ThreadGroupRow>(&sql)
            .bind(user_id)
            .fetch_all(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_thread_group(
        &self,
        id: i64,
        user_id: i64,
    ) -> anyhow::Result<Option<ThreadGroupRow>> {
        sqlx::query_as::<_, ThreadGroupRow>(
            "SELECT * FROM thread_groups WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn rename_thread_group(
        &self,
        id: i64,
        user_id: i64,
        name: &str,
    ) -> anyhow::Result<()> {
        sqlx::query("UPDATE thread_groups SET name = ? WHERE id = ? AND user_id = ?")
            .bind(name)
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_thread_group(&self, id: i64, user_id: i64) -> anyhow::Result<()> {
        // Threads in this group will have thread_group_id set to NULL via ON DELETE SET NULL.
        sqlx::query("DELETE FROM thread_groups WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// Move a thread to a group (or ungroup it if group_id is None).
    pub async fn move_thread_to_group(
        &self,
        thread_id: &str,
        user_id: i64,
        group_id: Option<i64>,
    ) -> anyhow::Result<()> {
        // If setting a group, verify ownership.
        if let Some(gid) = group_id {
            match self.get_thread_group(gid, user_id).await? {
                Some(_) => {}
                None => anyhow::bail!("group not found"),
            }
        }
        sqlx::query("UPDATE threads SET thread_group_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
            .bind(group_id)
            .bind(thread_id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// Get the next available position for a new group.
    pub async fn next_group_position(&self, user_id: i64) -> anyhow::Result<i64> {
        let max: Option<i64> =
            sqlx::query_scalar("SELECT MAX(position) FROM thread_groups WHERE user_id = ?")
                .bind(user_id)
                .fetch_one(self.pool())
                .await?;
        Ok(max.unwrap_or(-1) + 1)
    }
}
