//! Thread data access.

use super::messages::NewMessage;
use super::ThreadRow;

pub struct NewThread {
    pub id: String,
    pub user_id: i64,
    pub project_id: i64,
    pub thread_group_id: Option<i64>,
    pub title: String,
    pub title_user_set: bool,
    pub provider_id: String,
    pub model: String,
    pub permission_mode: String,
    pub reasoning_effort: String,
    pub permissions: Option<String>,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    pub env_mode: String,
    pub linked_mr: Option<String>,
}

/// Fields a `PATCH /threads/:id` may update. `None` leaves a column alone;
/// `Some(None)` clears a nullable column.
#[derive(Default)]
pub struct ThreadSettingsUpdate {
    pub provider: Option<String>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    pub reasoning_effort: Option<String>,
    pub permissions: Option<Option<String>>,
    pub env_mode: Option<String>,
    pub linked_mr: Option<Option<String>>,
    /// `Some(Some(n))` sets the output token cap, `Some(None)` clears it.
    pub max_output_tokens: Option<Option<i64>>,
}

impl super::Db {
    pub async fn create_thread(&self, new: NewThread) -> anyhow::Result<ThreadRow> {
        sqlx::query_as::<_, ThreadRow>(
            "INSERT INTO threads (id, user_id, project_id, thread_group_id, title, title_user_set, provider_id, model, permission_mode, reasoning_effort, permissions, branch, worktree_path, env_mode, linked_mr)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.id)
        .bind(new.user_id)
        .bind(new.project_id)
        .bind(new.thread_group_id)
        .bind(&new.title)
        .bind(new.title_user_set)
        .bind(&new.provider_id)
        .bind(&new.model)
        .bind(&new.permission_mode)
        .bind(&new.reasoning_effort)
        .bind(&new.permissions)
        .bind(&new.branch)
        .bind(&new.worktree_path)
        .bind(&new.env_mode)
        .bind(&new.linked_mr)
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
            "SELECT threads.*, (SELECT role FROM messages WHERE messages.thread_id = threads.id ORDER BY id DESC LIMIT 1) AS last_message_role,
             EXISTS(SELECT 1 FROM messages unseen
                    WHERE unseen.thread_id = threads.id
                      AND unseen.role IN ('assistant', 'error')
                      AND unseen.id > threads.viewed_message_id) AS unread
             FROM threads WHERE user_id = ? ORDER BY pinned DESC, updated_at DESC, id DESC"
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
        sqlx::query_as::<_, ThreadRow>(
            "SELECT threads.*, (SELECT role FROM messages WHERE messages.thread_id = threads.id ORDER BY id DESC LIMIT 1) AS last_message_role,
             EXISTS(SELECT 1 FROM messages unseen
                    WHERE unseen.thread_id = threads.id
                      AND unseen.role IN ('assistant', 'error')
                      AND unseen.id > threads.viewed_message_id) AS unread
             FROM threads WHERE id = ? AND user_id = ?",
        )
            .bind(id)
            .bind(user_id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Persist the provider session id. `provider_id` must match the thread's
    /// current provider, so a session created just before a provider change
    /// cannot be stored under the wrong provider.
    pub async fn update_thread_session(
        &self,
        id: &str,
        provider_id: &str,
        devin_session_id: &str,
        title: Option<&str>,
    ) -> anyhow::Result<()> {
        let changed = if let Some(title) = title {
            sqlx::query(
                "UPDATE threads
                 SET devin_session_id = ?,
                     title = CASE WHEN title_user_set = 0 THEN ? ELSE title END,
                     title_user_set = CASE WHEN title_user_set = 0 THEN 1 ELSE title_user_set END,
                     updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                 WHERE id = ? AND provider_id = ?",
            )
            .bind(devin_session_id)
            .bind(title)
            .bind(id)
            .bind(provider_id)
            .execute(self.pool())
            .await?
        } else {
            sqlx::query("UPDATE threads SET devin_session_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND provider_id = ?")
                .bind(devin_session_id).bind(id).bind(provider_id)
                .execute(self.pool()).await?
        };
        if changed.rows_affected() == 0 {
            anyhow::bail!("thread provider changed while the session was starting");
        }
        Ok(())
    }

    /// Watermark the thread as seen by its owner: the viewed message id moves
    /// to whatever is newest right now. `updated_at` is left alone so simply
    /// viewing a thread does not reorder the sidebar. Returns the matched
    /// row count; zero means no such thread.
    pub async fn mark_thread_viewed(&self, id: &str, user_id: i64) -> anyhow::Result<u64> {
        let changed = sqlx::query(
            "UPDATE threads
             SET viewed_message_id = (SELECT COALESCE(MAX(id), 0) FROM messages WHERE thread_id = ?)
             WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(id)
        .bind(user_id)
        .execute(self.pool())
        .await?;
        Ok(changed.rows_affected())
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

    /// Mark threads orphaned by a server shutdown as failed.
    ///
    /// Runs exist only in memory, so a crash, power loss, or SIGKILL leaves
    /// an in-flight run's last persisted message as the user's prompt. With
    /// no runner around to report otherwise the UI derives "working" from
    /// that trailing user message forever. Called once at startup — before
    /// any new run can start — this appends an error message to every such
    /// thread so it surfaces as failed. Returns the reconciled thread ids.
    /// A failure on one thread is logged and skipped so it cannot strand
    /// the rest.
    pub async fn fail_interrupted_runs(&self, detail: &str) -> anyhow::Result<Vec<String>> {
        let ids: Vec<String> = sqlx::query_scalar(
            "SELECT id FROM threads t
             WHERE (SELECT role FROM messages WHERE messages.thread_id = t.id
                    ORDER BY id DESC LIMIT 1) = 'user'
             ORDER BY t.id",
        )
        .fetch_all(self.pool())
        .await?;

        let mut done = Vec::with_capacity(ids.len());
        for id in ids {
            let result = async {
                self.add_message(NewMessage {
                    thread_id: id.clone(),
                    role: "error".into(),
                    content: detail.to_string(),
                    thinking: None,
                    parts: "[]".into(),
                    attachments: "[]".into(),
                    model: String::new(),
                    client_message_id: None,
                })
                .await?;
                self.touch_thread(&id).await
            }
            .await;
            match result {
                Ok(()) => done.push(id),
                Err(e) => {
                    tracing::warn!(thread_id = %id, error = %e, "failed to mark interrupted run")
                }
            }
        }
        Ok(done)
    }

    pub async fn rename_thread(&self, id: &str, user_id: i64, title: &str) -> anyhow::Result<()> {
        sqlx::query("UPDATE threads SET title = ?, title_user_set = 1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
            .bind(title)
            .bind(id)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// Update the title from the first user message if it has not already been
    /// set by the user. Returns the new `updated_at` when the title changes.
    pub async fn update_title_from_send(
        &self,
        id: &str,
        user_id: i64,
        title: &str,
    ) -> anyhow::Result<Option<String>> {
        let updated_at: Option<String> = sqlx::query_scalar(
            "UPDATE threads
             SET title = ?, title_user_set = 1, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE id = ? AND user_id = ? AND title_user_set = 0
             RETURNING updated_at",
        )
        .bind(title)
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await?;
        Ok(updated_at)
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
        update: ThreadSettingsUpdate,
    ) -> anyhow::Result<()> {
        let mut tx = self.pool().begin().await?;
        if let Some(provider) = update.provider.as_deref() {
            // A session id only means something to the provider that created
            // it, so the provider can only change while no session exists.
            // Guard at the database level so a concurrent send cannot slip a
            // session write between the API check and this update.
            let changed = sqlx::query(
                "UPDATE threads SET provider_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ? AND devin_session_id IS NULL",
            )
            .bind(provider)
            .bind(id)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
            if changed.rows_affected() == 0 {
                anyhow::bail!("provider cannot be changed once the conversation has started");
            }
        }
        if let Some(model) = update.model.as_deref() {
            sqlx::query("UPDATE threads SET model = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(model)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(mode) = update.permission_mode.as_deref() {
            sqlx::query("UPDATE threads SET permission_mode = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(mode)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(effort) = update.reasoning_effort.as_deref() {
            sqlx::query("UPDATE threads SET reasoning_effort = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(effort)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(perms) = update.permissions {
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
        if let Some(env_mode) = update.env_mode {
            sqlx::query("UPDATE threads SET env_mode = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(env_mode)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        if let Some(linked_mr) = update.linked_mr {
            if let Some(linked_mr) = linked_mr {
                sqlx::query("UPDATE threads SET linked_mr = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                    .bind(linked_mr)
                    .bind(id)
                    .bind(user_id)
                    .execute(&mut *tx).await?;
            } else {
                sqlx::query("UPDATE threads SET linked_mr = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                    .bind(id)
                    .bind(user_id)
                    .execute(&mut *tx).await?;
            }
        }
        if let Some(max_output) = update.max_output_tokens {
            sqlx::query("UPDATE threads SET max_output_tokens = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?")
                .bind(max_output)
                .bind(id)
                .bind(user_id)
                .execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Drop the provider session and watermark the context estimate at the
    /// thread's newest message. The next send starts a fresh provider
    /// session, so the token estimate only counts what the new session will
    /// see: messages written after this point.
    pub async fn reset_thread_context(&self, id: &str, user_id: i64) -> anyhow::Result<u64> {
        let changed = sqlx::query(
            "UPDATE threads
             SET devin_session_id = NULL,
                 context_cleared_seq = COALESCE((SELECT MAX(seq) FROM messages WHERE thread_id = ?), 0),
                 updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE id = ? AND user_id = ?",
        )
        .bind(id)
        .bind(id)
        .bind(user_id)
        .execute(self.pool())
        .await?;
        Ok(changed.rows_affected())
    }

    /// Update a thread's git fields. Returns the number of rows updated; a
    /// zero means the thread was deleted, which callers creating resources
    /// on its behalf use to roll back.
    pub async fn update_thread_git(
        &self,
        id: &str,
        user_id: i64,
        branch: Option<&str>,
        worktree_path: Option<&str>,
    ) -> anyhow::Result<u64> {
        let result = sqlx::query(
            "UPDATE threads SET branch = COALESCE(?, branch), worktree_path = COALESCE(?, worktree_path), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?",
        )
        .bind(branch)
        .bind(worktree_path)
        .bind(id)
        .bind(user_id)
        .execute(self.pool())
        .await?;
        Ok(result.rows_affected())
    }

    /// Flip a thread's env_mode without touching the other settings columns.
    /// Used when the agent creates its own worktree mid-run and the thread
    /// needs to switch from local to worktree mode so subsequent prompts keep
    /// running inside that worktree.
    pub async fn update_thread_env_mode(
        &self,
        id: &str,
        user_id: i64,
        env_mode: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE threads SET env_mode = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ? AND user_id = ?",
        )
        .bind(env_mode)
        .bind(id)
        .bind(user_id)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Delete a thread, returning the removed row so callers can clean up
    /// resources it referenced (worktree, branch). `None` means no thread
    /// matched.
    pub async fn delete_thread(&self, id: &str, user_id: i64) -> anyhow::Result<Option<ThreadRow>> {
        sqlx::query_as::<_, ThreadRow>(
            "DELETE FROM threads WHERE id = ? AND user_id = ? RETURNING *",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
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
        let sql = format!("SELECT id FROM threads WHERE user_id = ? AND id IN ({placeholders})");
        let mut query = sqlx::query_as::<_, (String,)>(&sql).bind(user_id);
        for id in thread_ids {
            query = query.bind(id);
        }
        let rows = query.fetch_all(self.pool()).await?;
        Ok(rows.into_iter().map(|r| r.0).collect())
    }

    /// Delete all threads for a user+project that have zero messages.
    /// Returns the deleted rows so callers can clean up resources they
    /// referenced (worktree, branch).
    pub async fn delete_empty_threads(
        &self,
        user_id: i64,
        project_id: i64,
    ) -> anyhow::Result<Vec<ThreadRow>> {
        sqlx::query_as::<_, ThreadRow>(
            "DELETE FROM threads
             WHERE user_id = ? AND project_id = ?
               AND id NOT IN (SELECT DISTINCT thread_id FROM messages)
             RETURNING *",
        )
        .bind(user_id)
        .bind(project_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::messages::NewMessage;
    use crate::db::users::NewUser;
    use crate::db::Db;

    async fn db() -> Db {
        Db::connect("sqlite::memory:").await.unwrap()
    }

    async fn user(db: &Db) -> i64 {
        db.create_user(NewUser {
            username: "u".into(),
            password_hash: "x".into(),
            is_owner: true,
        })
        .await
        .unwrap()
        .id
    }

    async fn thread(db: &Db, id: &str, user_id: i64) {
        let project_id = db
            .create_project(crate::db::projects::NewProject {
                user_id,
                name: format!("p-{id}"),
                path: format!("/tmp/p-{id}"),
                position: 0,
                project_type: "local".into(),
                node_id: None,
            })
            .await
            .unwrap()
            .id;
        db.create_thread(NewThread {
            id: id.into(),
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
    }

    async fn message(db: &Db, thread_id: &str, role: &str) {
        db.add_message(NewMessage {
            thread_id: thread_id.into(),
            role: role.into(),
            content: "msg".into(),
            thinking: None,
            parts: "[]".into(),
            attachments: "[]".into(),
            model: String::new(),
            client_message_id: None,
        })
        .await
        .unwrap();
    }

    async fn last_role(db: &Db, user_id: i64, thread_id: &str) -> Option<String> {
        db.get_thread(thread_id, user_id)
            .await
            .unwrap()
            .unwrap()
            .last_message_role
    }

    #[tokio::test]
    async fn fail_interrupted_runs_marks_orphaned_threads_failed() {
        let db = db().await;
        let uid = user(&db).await;
        thread(&db, "orphan", uid).await;
        thread(&db, "finished", uid).await;
        thread(&db, "empty", uid).await;
        message(&db, "orphan", "user").await;
        message(&db, "finished", "user").await;
        message(&db, "finished", "assistant").await;

        let failed = db.fail_interrupted_runs("server stopped").await.unwrap();
        assert_eq!(failed, vec!["orphan".to_string()]);

        // The orphaned thread now ends in an error message, so the UI shows
        // it as failed instead of stuck on "working".
        assert_eq!(
            last_role(&db, uid, "orphan").await.as_deref(),
            Some("error")
        );
        let msgs = db.list_messages("orphan").await.unwrap();
        assert_eq!(msgs.last().unwrap().role, "error");
        assert_eq!(msgs.last().unwrap().content, "server stopped");
        // The error joins the open turn rather than starting a new one.
        assert_eq!(msgs.last().unwrap().turn_id, msgs[0].turn_id);

        // Threads that already finished or never ran stay untouched.
        assert_eq!(
            last_role(&db, uid, "finished").await.as_deref(),
            Some("assistant")
        );
        assert_eq!(last_role(&db, uid, "empty").await, None);
        assert_eq!(db.list_messages("finished").await.unwrap().len(), 2);
        assert!(db.list_messages("empty").await.unwrap().is_empty());

        // A second pass is a no-op: nothing ends in a user message anymore.
        assert!(db
            .fail_interrupted_runs("server stopped")
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn fail_interrupted_runs_ignores_error_and_system_tails() {
        let db = db().await;
        let uid = user(&db).await;
        thread(&db, "errored", uid).await;
        thread(&db, "system", uid).await;
        message(&db, "errored", "user").await;
        message(&db, "errored", "error").await;
        message(&db, "system", "system").await;

        assert!(db
            .fail_interrupted_runs("server stopped")
            .await
            .unwrap()
            .is_empty());
        assert_eq!(
            last_role(&db, uid, "errored").await.as_deref(),
            Some("error")
        );
        assert_eq!(
            last_role(&db, uid, "system").await.as_deref(),
            Some("system")
        );
    }
}
