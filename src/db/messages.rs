//! Message data access.

use super::MessageRow;

pub struct NewMessage {
    pub thread_id: String,
    pub role: String,
    pub content: String,
    pub thinking: Option<String>,
    pub parts: String,
    pub attachments: String,
}

impl super::Db {
    pub async fn add_message(&self, new: NewMessage) -> anyhow::Result<MessageRow> {
        sqlx::query_as::<_, MessageRow>(
            "INSERT INTO messages (thread_id, role, content, thinking, parts, attachments)
             VALUES (?, ?, ?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.thread_id)
        .bind(&new.role)
        .bind(&new.content)
        .bind(&new.thinking)
        .bind(&new.parts)
        .bind(&new.attachments)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn delete_message(&self, id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM messages WHERE id = ?")
            .bind(id)
            .execute(self.pool())
            .await
            .map_err(Into::into)
            .map(|_| ())
    }

    pub async fn list_messages(&self, thread_id: &str) -> anyhow::Result<Vec<MessageRow>> {
        sqlx::query_as::<_, MessageRow>(
            "SELECT * FROM messages WHERE thread_id = ? ORDER BY id ASC",
        )
        .bind(thread_id)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn count_messages(&self, thread_id: &str) -> anyhow::Result<i64> {
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM messages WHERE thread_id = ?",
        )
        .bind(thread_id)
        .fetch_one(self.pool())
        .await?;
        Ok(row.0)
    }

    /// Returns at most `limit` messages around the requested cursor.
    ///
    /// - If `after_id` is given, returns the next messages with `id > after_id`
    ///   in ascending order.
    /// - If `before_id` is given, returns the previous messages with `id < before_id`
    ///   in ascending order (i.e. the page that ends just before the cursor).
    /// - If neither is given, returns the most recent `limit` messages.
    pub async fn list_messages_paginated(
        &self,
        thread_id: &str,
        before_id: Option<i64>,
        after_id: Option<i64>,
        limit: i64,
    ) -> anyhow::Result<Vec<MessageRow>> {
        if limit <= 0 {
            return Ok(Vec::new());
        }

        match (before_id, after_id) {
            (Some(before), _) => {
                sqlx::query_as::<_, MessageRow>(
                    "SELECT * FROM (
                        SELECT * FROM messages
                        WHERE thread_id = ? AND id < ?
                        ORDER BY id DESC LIMIT ?
                    ) ORDER BY id ASC",
                )
                .bind(thread_id)
                .bind(before)
                .bind(limit)
                .fetch_all(self.pool())
                .await
            }
            (None, Some(after)) => {
                sqlx::query_as::<_, MessageRow>(
                    "SELECT * FROM messages
                     WHERE thread_id = ? AND id > ?
                     ORDER BY id ASC LIMIT ?",
                )
                .bind(thread_id)
                .bind(after)
                .bind(limit)
                .fetch_all(self.pool())
                .await
            }
            (None, None) => {
                sqlx::query_as::<_, MessageRow>(
                    "SELECT * FROM (
                        SELECT * FROM messages
                        WHERE thread_id = ?
                        ORDER BY id DESC LIMIT ?
                    ) ORDER BY id ASC",
                )
                .bind(thread_id)
                .bind(limit)
                .fetch_all(self.pool())
                .await
            }
        }
        .map_err(Into::into)
    }
}
