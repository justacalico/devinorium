//! Public thread share storage.
//!
//! A share freezes the thread's transcript at publish time into `snapshot`
//! (a JSON array of [`SharedMessage`]) and serves it at an unguessable
//! `/shared/<id>` URL. One share per thread; re-sharing replaces the
//! snapshot in place so the link stays stable.

use serde::{Deserialize, Serialize};

use crate::providers::MessagePart;

/// A row from the `thread_shares` table.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct ThreadShareRow {
    pub id: String,
    pub thread_id: String,
    pub user_id: i64,
    pub title: String,
    pub provider_id: String,
    /// JSON array of [`SharedMessage`].
    pub snapshot: String,
    pub created_at: String,
}

/// One message inside a share snapshot. Trimmed to what the public page
/// renders; internal ids and bookkeeping fields stay out of the published
/// copy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedMessage {
    pub role: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
    #[serde(default)]
    pub parts: Vec<MessagePart>,
    #[serde(default)]
    pub attachments: serde_json::Value,
    #[serde(default)]
    pub model: String,
    /// True when the stored row was cut down to the per-message budget; the
    /// shared page renders a notice instead of pretending completeness.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    pub created_at: String,
}

impl super::Db {
    /// Create or refresh the share for a thread. The share id (and thus the
    /// public URL) survives a re-share; only the payload moves.
    pub async fn upsert_thread_share(
        &self,
        share_id: &str,
        thread_id: &str,
        user_id: i64,
        title: &str,
        provider_id: &str,
        snapshot: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO thread_shares (id, thread_id, user_id, title, provider_id, snapshot)
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(thread_id) DO UPDATE SET
               title = excluded.title,
               provider_id = excluded.provider_id,
               snapshot = excluded.snapshot",
        )
        .bind(share_id)
        .bind(thread_id)
        .bind(user_id)
        .bind(title)
        .bind(provider_id)
        .bind(snapshot)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Fetch a share by its public id.
    pub async fn get_thread_share(&self, share_id: &str) -> anyhow::Result<Option<ThreadShareRow>> {
        sqlx::query_as::<_, ThreadShareRow>("SELECT * FROM thread_shares WHERE id = ?")
            .bind(share_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Fetch the share belonging to a thread, if any.
    pub async fn get_share_for_thread(
        &self,
        thread_id: &str,
    ) -> anyhow::Result<Option<ThreadShareRow>> {
        sqlx::query_as::<_, ThreadShareRow>("SELECT * FROM thread_shares WHERE thread_id = ?")
            .bind(thread_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Just the public id of a thread's share — no snapshot blob.
    pub async fn share_id_for_thread(&self, thread_id: &str) -> anyhow::Result<Option<String>> {
        sqlx::query_scalar("SELECT id FROM thread_shares WHERE thread_id = ?")
            .bind(thread_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Revoke a thread's share. Returns the rows matched so callers can tell
    /// "was never shared" from success.
    pub async fn delete_thread_share(&self, thread_id: &str, user_id: i64) -> anyhow::Result<u64> {
        let res = sqlx::query("DELETE FROM thread_shares WHERE thread_id = ? AND user_id = ?")
            .bind(thread_id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected())
    }
}

#[cfg(test)]
mod tests {
    use crate::db::threads::NewThread;
    use crate::db::users::NewUser;
    use crate::db::Db;

    async fn fixture() -> (Db, i64, String) {
        let db = Db::connect("sqlite::memory:").await.unwrap();
        let user_id = db
            .create_user(NewUser {
                username: "u".into(),
                password_hash: "x".into(),
                is_owner: true,
            })
            .await
            .unwrap()
            .id;
        let project_id = db
            .create_project(crate::db::projects::NewProject {
                user_id,
                name: "p".into(),
                path: "/tmp/p".into(),
                position: 0,
                project_type: "local".into(),
                node_id: None,
            })
            .await
            .unwrap()
            .id;
        let thread_id = "th-1".to_string();
        db.create_thread(NewThread {
            id: thread_id.clone(),
            user_id,
            project_id,
            thread_group_id: None,
            title: "t".into(),
            title_user_set: false,
            provider_id: "devin-cli".into(),
            model: "m".into(),
            permission_mode: "normal".into(),
            reasoning_effort: String::new(),
            permissions: None,
            branch: None,
            worktree_path: None,
            env_mode: "local".into(),
            linked_mr: None,
        })
        .await
        .unwrap();
        (db, user_id, thread_id)
    }

    #[tokio::test]
    async fn upsert_creates_and_refreshes_in_place() {
        let (db, user_id, thread_id) = fixture().await;
        db.upsert_thread_share("sh-1", &thread_id, user_id, "title", "devin-cli", "[]")
            .await
            .unwrap();
        let row = db.get_thread_share("sh-1").await.unwrap().unwrap();
        assert_eq!(row.thread_id, thread_id);
        assert_eq!(row.snapshot, "[]");

        // Re-sharing a different id keeps the existing row: the UNIQUE
        // thread_id conflict path updates instead of inserting.
        db.upsert_thread_share("sh-2", &thread_id, user_id, "title2", "codex", "[1]")
            .await
            .unwrap();
        let row = db.get_share_for_thread(&thread_id).await.unwrap().unwrap();
        assert_eq!(row.id, "sh-1", "share id must stay stable across re-shares");
        assert_eq!(row.title, "title2");
        assert_eq!(row.provider_id, "codex");
        assert_eq!(row.snapshot, "[1]");
    }

    #[tokio::test]
    async fn delete_revokes_share() {
        let (db, user_id, thread_id) = fixture().await;
        db.upsert_thread_share("sh-1", &thread_id, user_id, "t", "p", "[]")
            .await
            .unwrap();
        assert_eq!(
            db.delete_thread_share(&thread_id, user_id).await.unwrap(),
            1
        );
        assert!(db.get_thread_share("sh-1").await.unwrap().is_none());
        // A second delete is a no-op, not an error.
        assert_eq!(
            db.delete_thread_share(&thread_id, user_id).await.unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn thread_delete_cascades_share() {
        let (db, user_id, thread_id) = fixture().await;
        db.upsert_thread_share("sh-1", &thread_id, user_id, "t", "p", "[]")
            .await
            .unwrap();
        db.delete_thread(&thread_id, user_id).await.unwrap();
        assert!(db.get_thread_share("sh-1").await.unwrap().is_none());
    }
}
