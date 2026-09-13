//! Project group data access.
//!
//! Project groups organize the sidebar project list. A project belongs to at
//! most one group; `group_id = NULL` means ungrouped. Deleting a group sets
//! its projects' `group_id` back to NULL via `ON DELETE SET NULL`.

use super::ProjectGroupRow;

pub struct NewProjectGroup {
    pub user_id: i64,
    pub name: String,
    pub position: i64,
}

impl super::Db {
    pub async fn create_project_group(
        &self,
        new: NewProjectGroup,
    ) -> anyhow::Result<ProjectGroupRow> {
        sqlx::query_as::<_, ProjectGroupRow>(
            "INSERT INTO project_groups (user_id, name, position)
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

    pub async fn list_project_groups(
        &self,
        user_id: i64,
        limit: Option<i64>,
        offset: i64,
    ) -> anyhow::Result<Vec<ProjectGroupRow>> {
        let mut sql =
            "SELECT * FROM project_groups WHERE user_id = ? ORDER BY position ASC, id ASC"
                .to_string();
        if let Some(l) = limit {
            sql.push_str(&format!(" LIMIT {l} OFFSET {offset}"));
        }
        sqlx::query_as::<_, ProjectGroupRow>(&sql)
            .bind(user_id)
            .fetch_all(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_project_group(
        &self,
        id: i64,
        user_id: i64,
    ) -> anyhow::Result<Option<ProjectGroupRow>> {
        sqlx::query_as::<_, ProjectGroupRow>(
            "SELECT * FROM project_groups WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn get_project_group_by_name(
        &self,
        user_id: i64,
        name: &str,
    ) -> anyhow::Result<Option<ProjectGroupRow>> {
        sqlx::query_as::<_, ProjectGroupRow>(
            "SELECT * FROM project_groups WHERE user_id = ? AND name = ?",
        )
        .bind(user_id)
        .bind(name)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn rename_project_group(
        &self,
        id: i64,
        user_id: i64,
        name: &str,
    ) -> anyhow::Result<()> {
        sqlx::query("UPDATE project_groups SET name = ? WHERE id = ? AND user_id = ?")
            .bind(name)
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    pub async fn delete_project_group(&self, id: i64, user_id: i64) -> anyhow::Result<u64> {
        // Member projects get group_id = NULL via ON DELETE SET NULL.
        let res = sqlx::query("DELETE FROM project_groups WHERE id = ? AND user_id = ?")
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected())
    }

    /// Assign a project to a group (or ungroup it with `None`). Returns an
    /// error when the group or project does not belong to the user.
    pub async fn set_project_group(
        &self,
        project_id: i64,
        user_id: i64,
        group_id: Option<i64>,
    ) -> anyhow::Result<()> {
        if let Some(gid) = group_id {
            if self.get_project_group(gid, user_id).await?.is_none() {
                anyhow::bail!("group not found");
            }
        }
        let res = sqlx::query(
            "UPDATE projects SET group_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?",
        )
        .bind(group_id)
        .bind(project_id)
        .bind(user_id)
        .execute(self.pool())
        .await?;
        if res.rows_affected() == 0 {
            anyhow::bail!("project not found");
        }
        Ok(())
    }

    /// Return the subset of `project_ids` that belong to the user.
    pub async fn owned_project_ids(
        &self,
        user_id: i64,
        project_ids: &[i64],
    ) -> anyhow::Result<Vec<i64>> {
        if project_ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = project_ids
            .iter()
            .map(|_| "?")
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!("SELECT id FROM projects WHERE user_id = ? AND id IN ({placeholders})");
        let mut query = sqlx::query_as::<_, (i64,)>(&sql).bind(user_id);
        for id in project_ids {
            query = query.bind(id);
        }
        let rows = query.fetch_all(self.pool()).await?;
        Ok(rows.into_iter().map(|r| r.0).collect())
    }

    pub async fn next_project_group_position(&self, user_id: i64) -> anyhow::Result<i64> {
        let max: Option<i64> =
            sqlx::query_scalar("SELECT MAX(position) FROM project_groups WHERE user_id = ?")
                .bind(user_id)
                .fetch_one(self.pool())
                .await?;
        Ok(max.unwrap_or(-1) + 1)
    }
}
