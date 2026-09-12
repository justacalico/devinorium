//! Message attachment blob storage.
//!
//! Files uploaded with a user message land here so the UI can render
//! thumbnails and download originals long after the turn finished. The `idx`
//! column equals the `index` field in the message's `attachments` metadata:
//! the upload's position among the sent files (path and thread references
//! carry no index and have no blob).

use crate::providers::Attachment;

#[derive(Debug, sqlx::FromRow)]
pub struct MessageAttachmentRow {
    pub filename: String,
    pub mime: String,
    pub data: Vec<u8>,
}

impl super::Db {
    /// Persist the uploaded attachments of a message, keyed by their position
    /// in the message's attachment metadata list.
    pub async fn add_message_attachments(
        &self,
        message_id: i64,
        attachments: &[Attachment],
    ) -> anyhow::Result<()> {
        if attachments.is_empty() {
            return Ok(());
        }
        let mut tx = self.pool().begin().await?;
        for (i, att) in attachments.iter().enumerate() {
            sqlx::query(
                "INSERT INTO message_attachments (message_id, idx, filename, mime, data)
                 VALUES (?, ?, ?, ?, ?)",
            )
            .bind(message_id)
            .bind(i as i64)
            .bind(&att.filename)
            .bind(&att.mime)
            .bind(&att.data)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    /// Fetch one stored attachment, scoped to the thread that owns the
    /// message so a caller cannot read another thread's uploads by guessing
    /// a message id.
    pub async fn get_message_attachment(
        &self,
        thread_id: &str,
        message_id: i64,
        idx: i64,
    ) -> anyhow::Result<Option<MessageAttachmentRow>> {
        sqlx::query_as::<_, MessageAttachmentRow>(
            "SELECT ma.filename, ma.mime, ma.data
             FROM message_attachments ma
             JOIN messages m ON m.id = ma.message_id
             WHERE m.thread_id = ? AND ma.message_id = ? AND ma.idx = ?",
        )
        .bind(thread_id)
        .bind(message_id)
        .bind(idx)
        .fetch_optional(self.pool())
        .await
        .map_err(Into::into)
    }
}
