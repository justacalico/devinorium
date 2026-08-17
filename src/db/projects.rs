//! Project data access.

use super::{Db, ProjectRow};

pub struct NewProject {
    pub user_id: i64,
    pub name: String,
    pub path: String,
    pub position: i64,
}

impl Db {
    pub async fn create_project(&self, new: NewProject) -> anyhow::Result<ProjectRow> {
        sqlx::query_as::<_, ProjectRow>(
            "INSERT INTO projects (user_id, name, path, position)
             VALUES (?, ?, ?, ?)
             RETURNING *",
        )
        .bind(new.user_id)
        .bind(&new.name)
        .bind(&new.path)
        .bind(new.position)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_projects(&self, user_id: i64) -> anyhow::Result<Vec<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>(
            "SELECT * FROM projects WHERE user_id = ? ORDER BY position ASC, id ASC",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn next_project_position(&self, user_id: i64) -> anyhow::Result<i64> {
        let max: Option<i64> =
            sqlx::query_scalar("SELECT MAX(position) FROM projects WHERE user_id = ?")
                .bind(user_id)
                .fetch_one(self.pool())
                .await?;
        Ok(max.unwrap_or(-1) + 1)
    }

    pub async fn update_project_positions(
        &self,
        user_id: i64,
        ids: &[i64],
    ) -> anyhow::Result<()> {
        let mut tx = self.pool().begin().await?;

        let current: Vec<i64> =
            sqlx::query_scalar("SELECT id FROM projects WHERE user_id = ? ORDER BY position ASC, id ASC")
                .bind(user_id)
                .fetch_all(&mut *tx)
                .await?;

        let current_set: std::collections::HashSet<_> = current.iter().copied().collect();
        let requested_set: std::collections::HashSet<_> = ids.iter().copied().collect();
        if current_set != requested_set {
            anyhow::bail!("reorder request does not match user's projects");
        }

        for (i, id) in ids.iter().enumerate() {
            sqlx::query(
                "UPDATE projects SET position = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?",
            )
            .bind(i as i64)
            .bind(*id)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
        }

        tx.commit().await?;
        Ok(())
    }

    pub async fn get_project(&self, id: i64, user_id: i64) -> anyhow::Result<Option<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_project_by_path(
        &self,
        user_id: i64,
        path: &str,
    ) -> anyhow::Result<Option<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE user_id = ? AND path = ?")
            .bind(user_id)
            .bind(path)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_project_by_name(
        &self,
        user_id: i64,
        name: &str,
    ) -> anyhow::Result<Option<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE user_id = ? AND name = ?")
            .bind(user_id)
            .bind(name)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn delete_project(&self, id: i64, user_id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM projects WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn list_threads_for_project(
        &self,
        project_id: i64,
        user_id: i64,
    ) -> anyhow::Result<Vec<super::ThreadRow>> {
        sqlx::query_as::<_, super::ThreadRow>(
            "SELECT * FROM threads
             WHERE project_id = ? AND user_id = ?
             ORDER BY updated_at DESC",
        )
        .bind(project_id)
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }
}
