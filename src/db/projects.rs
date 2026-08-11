//! Project data access.

use super::{Db, ProjectRow};

pub struct NewProject {
    pub user_id: i64,
    pub name: String,
    pub path: String,
}

impl Db {
    pub async fn create_project(&self, new: NewProject) -> anyhow::Result<ProjectRow> {
        sqlx::query_as::<_, ProjectRow>(
            "INSERT INTO projects (user_id, name, path)
             VALUES (?, ?, ?)
             RETURNING *",
        )
        .bind(new.user_id)
        .bind(&new.name)
        .bind(&new.path)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn list_projects(&self, user_id: i64) -> anyhow::Result<Vec<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>(
            "SELECT * FROM projects WHERE user_id = ? ORDER BY name ASC",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn get_project(&self, id: i64, user_id: i64) -> anyhow::Result<Option<ProjectRow>> {
        sqlx::query_as::<_, ProjectRow>(
            "SELECT * FROM projects WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn delete_project(&self, id: i64, user_id: i64) -> anyhow::Result<()> {
        sqlx::query(
            "DELETE FROM projects WHERE id = ? AND user_id = ?",
        )
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
