//! Thread data access.

use super::ThreadRow;

pub struct NewThread {
    pub id: String,
    pub user_id: i64,
    pub project_id: i64,
    pub thread_group_id: Option<i64>,
    pub title: String,
    pub model: String,
    pub permission_mode: String,
}

impl super::Db {
    pub async fn create_thread(&self, new: NewThread) -> anyhow::Result<ThreadRow> {
        sqlx::query_as::<_, ThreadRow>(
            "INSERT INTO threads (id, user_id, project_id, thread_group_id, title, model, permission_mode)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.id)
        .bind(new.user_id)
        .bind(new.project_id)
        .bind(new.thread_group_id)
        .bind(&new.title)
        .bind(&new.model)
        .bind(&new.permission_mode)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_threads(&self, user_id: i64) -> anyhow::Result<Vec<ThreadRow>> {
        sqlx::query_as::<_, ThreadRow>(
            "SELECT * FROM threads WHERE user_id = ? ORDER BY updated_at DESC",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn get_thread(&self, id: &str, user_id: i64) -> anyhow::Result<Option<ThreadRow>> {
        sqlx::query_as::<_, ThreadRow>("SELECT * FROM threads WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn update_thread_session(&self, id: &str, devin_session_id: &str, title: Option<&str>) -> anyhow::Result<()> {
        if let Some(title) = title {
            sqlx::query("UPDATE threads SET devin_session_id = ?, title = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?")
                .bind(devin_session_id).bind(title).bind(id)
                .execute(self.pool()).await?;
        } else {
            sqlx::query("UPDATE threads SET devin_session_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?")
                .bind(devin_session_id).bind(id)
                .execute(self.pool()).await?;
        }
        Ok(())
    }

    pub async fn touch_thread(&self, id: &str) -> anyhow::Result<()> {
        sqlx::query("UPDATE threads SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?")
            .bind(id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn rename_thread(&self, id: &str, user_id: i64, title: &str) -> anyhow::Result<()> {
        sqlx::query("UPDATE threads SET title = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
            .bind(title)
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_thread(&self, id: &str, user_id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM threads WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }
}
