//! Message data access.

use super::MessageRow;

pub struct NewMessage {
    pub thread_id: String,
    pub role: String,
    pub content: String,
    pub attachments: String,
}

impl super::Db {
    pub async fn add_message(&self, new: NewMessage) -> anyhow::Result<MessageRow> {
        sqlx::query_as::<_, MessageRow>(
            "INSERT INTO messages (thread_id, role, content, attachments)
             VALUES (?, ?, ?, ?)
             RETURNING *",
        )
        .bind(&new.thread_id)
        .bind(&new.role)
        .bind(&new.content)
        .bind(&new.attachments)
        .fetch_one(self.pool())
        .await
        .map_err(Into::into)
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
}
