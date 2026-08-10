//! Workspace data access.

use super::WorkspaceRow;

pub struct NewWorkspace {
    pub user_id: i64,
    pub path: String,
    pub label: String,
}

impl super::Db {
    pub async fn create_workspace(&self, new: NewWorkspace) -> anyhow::Result<WorkspaceRow> {
        sqlx::query_as::<_, WorkspaceRow>(
            "INSERT INTO workspaces (user_id, path, label) VALUES (?, ?, ?)
             RETURNING *",
        )
        .bind(new.user_id)
        .bind(&new.path)
        .bind(&new.label)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_workspaces(&self, user_id: i64) -> anyhow::Result<Vec<WorkspaceRow>> {
        sqlx::query_as::<_, WorkspaceRow>(
            "SELECT * FROM workspaces WHERE user_id = ? ORDER BY last_used_at DESC",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn get_workspace(&self, id: i64, user_id: i64) -> anyhow::Result<Option<WorkspaceRow>> {
        sqlx::query_as::<_, WorkspaceRow>(
            "SELECT * FROM workspaces WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn touch_workspace(&self, id: i64) -> anyhow::Result<()> {
        sqlx::query("UPDATE workspaces SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?")
            .bind(id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_workspace(&self, id: i64, user_id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM workspaces WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }
}
