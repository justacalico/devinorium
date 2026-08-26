//! Plan data access.

use crate::plan::{Plan, PlanStep};

/// A row from the `plans` table.
#[derive(Debug, Clone, serde::Serialize, sqlx::FromRow)]
pub struct PlanRow {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub explanation: Option<String>,
    pub steps: String,
    pub created_at: String,
    pub updated_at: String,
}

impl PlanRow {
    pub fn to_plan(&self) -> anyhow::Result<Plan> {
        let steps: Vec<PlanStep> = serde_json::from_str(&self.steps)?;
        Ok(Plan::new(self.explanation.clone(), steps))
    }
}

/// Input for saving a plan.
pub struct NewPlan {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub explanation: Option<String>,
    pub steps: Vec<PlanStep>,
}

impl super::Db {
    pub async fn get_latest_plan(&self, thread_id: &str) -> anyhow::Result<Option<PlanRow>> {
        sqlx::query_as::<_, PlanRow>(
            "SELECT * FROM plans WHERE thread_id = ? ORDER BY created_at DESC LIMIT 1",
        )
        .bind(thread_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn delete_plans_for_thread(&self, thread_id: &str) -> anyhow::Result<u64> {
        sqlx::query("DELETE FROM plans WHERE thread_id = ?")
            .bind(thread_id)
            .execute(self.pool())
            .await
            .map(|r| r.rows_affected())
            .map_err(Into::into)
    }

    pub async fn get_plan(&self, id: &str, thread_id: &str) -> anyhow::Result<Option<PlanRow>> {
        sqlx::query_as::<_, PlanRow>("SELECT * FROM plans WHERE id = ? AND thread_id = ?")
            .bind(id)
            .bind(thread_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn save_plan(&self, new: NewPlan) -> anyhow::Result<PlanRow> {
        let steps_json = serde_json::to_string(&new.steps)?;
        sqlx::query_as::<_, PlanRow>(
            "INSERT INTO plans (id, thread_id, run_id, explanation, steps)
             VALUES (?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.id)
        .bind(&new.thread_id)
        .bind(&new.run_id)
        .bind(&new.explanation)
        .bind(steps_json)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    /// Replace the latest plan for a thread. Used when the model streams many
    /// updates for the same turn: only the final plan is kept.
    pub async fn upsert_latest_plan(
        &self,
        thread_id: &str,
        run_id: Option<&str>,
        plan: &Plan,
    ) -> anyhow::Result<PlanRow> {
        let steps_json = serde_json::to_string(&plan.steps)?;
        sqlx::query_as::<_, PlanRow>(
            "INSERT INTO plans (id, thread_id, run_id, explanation, steps, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'), strftime('%Y-%m-%dT%H:%M:%fZ','now'))
             ON CONFLICT (thread_id, run_id) DO UPDATE SET
                 explanation = excluded.explanation,
                 steps = excluded.steps,
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
             RETURNING *",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(thread_id)
        .bind(run_id)
        .bind(&plan.explanation)
        .bind(steps_json)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }
}
