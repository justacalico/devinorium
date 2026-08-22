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
    pub permissions: Option<String>,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
}

impl super::Db {
    pub async fn create_thread(&self, new: NewThread) -> anyhow::Result<ThreadRow> {
        sqlx::query_as::<_, ThreadRow>(
            "INSERT INTO threads (id, user_id, project_id, thread_group_id, title, model, permission_mode, permissions, branch, worktree_path)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.id)
        .bind(new.user_id)
        .bind(new.project_id)
        .bind(new.thread_group_id)
        .bind(&new.title)
        .bind(&new.model)
        .bind(&new.permission_mode)
        .bind(&new.permissions)
        .bind(&new.branch)
        .bind(&new.worktree_path)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_threads(
        &self,
        user_id: i64,
        limit: Option<i64>,
        offset: i64,
    ) -> anyhow::Result<Vec<ThreadRow>> {
        let mut sql =
            "SELECT * FROM threads WHERE user_id = ? ORDER BY pinned DESC, updated_at DESC, id DESC"
                .to_string();
        if let Some(l) = limit {
            sql.push_str(&format!(" LIMIT {l} OFFSET {offset}"));
        }
        sqlx::query_as::<_, ThreadRow>(&sql)
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

    pub async fn update_thread_session(
        &self,
        id: &str,
        devin_session_id: &str,
        title: Option<&str>,
    ) -> anyhow::Result<()> {
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
        sqlx::query(
            "UPDATE threads SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?",
        )
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

    pub async fn set_thread_pinned(
        &self,
        id: &str,
        user_id: i64,
        pinned: bool,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE threads SET pinned = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ? AND pinned != ?",
        )
        .bind(pinned)
        .bind(id)
        .bind(user_id)
        .bind(pinned)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    pub async fn update_thread_settings(
        &self,
        id: &str,
        user_id: i64,
        model: Option<&str>,
        permission_mode: Option<&str>,
        permissions: Option<Option<&str>>,
    ) -> anyhow::Result<()> {
        let mut tx = self.pool().begin().await?;
        if let Some(model) = model {
            sqlx::query("UPDATE threads SET model = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(model)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(mode) = permission_mode {
            sqlx::query("UPDATE threads SET permission_mode = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(mode)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(perms) = permissions {
            if let Some(perms) = perms {
                sqlx::query("UPDATE threads SET permissions = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                    .bind(perms)
                    .bind(id)
                    .bind(user_id)
                    .execute(&mut *tx).await?;
            } else {
                sqlx::query("UPDATE threads SET permissions = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                    .bind(id)
                    .bind(user_id)
                    .execute(&mut *tx).await?;
            }
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn update_thread_git(
        &self,
        id: &str,
        user_id: i64,
        branch: Option<&str>,
        worktree_path: Option<&str>,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE threads SET branch = ?, worktree_path = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?",
        )
        .bind(branch)
        .bind(worktree_path)
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

    /// Return the subset of `thread_ids` that belong to the user.
    pub async fn filter_user_thread_ids(
        &self,
        user_id: i64,
        thread_ids: &[String],
    ) -> anyhow::Result<Vec<String>> {
        if thread_ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = thread_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!(
            "SELECT id FROM threads WHERE user_id = ? AND id IN ({placeholders})"
        );
        let mut query = sqlx::query_as::<_, (String,)>(&sql).bind(user_id);
        for id in thread_ids {
            query = query.bind(id);
        }
        let rows = query.fetch_all(self.pool()).await?;
        Ok(rows.into_iter().map(|r| r.0).collect())
    }

    /// Delete all threads for a user+project that have zero messages.
    /// Returns the number of threads deleted.
    pub async fn delete_empty_threads(
        &self,
        user_id: i64,
        project_id: i64,
    ) -> anyhow::Result<u64> {
        let result = sqlx::query(
            "DELETE FROM threads
             WHERE user_id = ? AND project_id = ?
               AND id NOT IN (SELECT DISTINCT thread_id FROM messages)",
        )
        .bind(user_id)
        .bind(project_id)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected())
    }
}
