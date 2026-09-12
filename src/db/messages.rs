//! Message data access.

use super::MessageRow;

pub const MESSAGE_CHAR_BUDGET: i64 = 100_000;
pub const MESSAGE_PARTS_BUDGET: i64 = 100_000;
pub const TURN_LIMIT_DEFAULT: i64 = 50;
pub const MAX_RAW_TURNS_PER_PAGE: i64 = 150;

/// Maximum length for a client-generated message id.
pub const MAX_CLIENT_MESSAGE_ID_LEN: usize = 64;

/// Error returned when a message with the same `client_message_id` already
/// exists in the thread.
#[derive(Debug, Clone, Copy)]
pub struct DuplicateClientMessageId;

impl std::fmt::Display for DuplicateClientMessageId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "a message with this client id already exists")
    }
}

impl std::error::Error for DuplicateClientMessageId {}

pub struct NewMessage {
    pub thread_id: String,
    pub role: String,
    pub content: String,
    pub thinking: Option<String>,
    pub parts: String,
    pub attachments: String,
    pub model: String,
    pub client_message_id: Option<String>,
}

/// Cursor for the next page of older turns.
///
/// The cursor is opaque to clients: it is base64-encoded as `"{turn_id}:{id}"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TurnCursor {
    pub turn_id: i64,
    pub id: i64,
}

impl TurnCursor {
    pub fn encode(&self) -> String {
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
        URL_SAFE_NO_PAD.encode(format!("{}:{}", self.turn_id, self.id))
    }

    pub fn decode(s: &str) -> Option<Self> {
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
        let bytes = URL_SAFE_NO_PAD.decode(s).ok()?;
        let text = std::str::from_utf8(&bytes).ok()?;
        let (turn, id) = text.split_once(':')?;
        Some(Self {
            turn_id: turn.parse().ok()?,
            id: id.parse().ok()?,
        })
    }
}

impl super::Db {
    pub async fn add_message(&self, new: NewMessage) -> anyhow::Result<MessageRow> {
        let mut conn = self.pool().acquire().await?;
        sqlx::query("BEGIN IMMEDIATE").execute(&mut *conn).await?;

        let result = sqlx::query_as::<_, MessageRow>(
            "INSERT INTO messages (thread_id, role, content, thinking, parts, attachments, model, client_message_id, turn_id, seq)
             VALUES (
                 ?, ?, ?, ?, ?, ?, ?, ?,
                 CASE
                     WHEN ? = 'user'
                         THEN (SELECT COALESCE(MAX(turn_id), 0) + 1 FROM messages WHERE thread_id = ?)
                     ELSE (SELECT COALESCE(MAX(turn_id), 0) FROM messages WHERE thread_id = ?)
                 END,
                 (SELECT COALESCE(MAX(seq), 0) + 1 FROM messages WHERE thread_id = ?)
             )
             RETURNING *",
        )
        .bind(&new.thread_id)
        .bind(&new.role)
        .bind(&new.content)
        .bind(&new.thinking)
        .bind(&new.parts)
        .bind(&new.attachments)
        .bind(&new.model)
        .bind(&new.client_message_id)
        .bind(&new.role)
        .bind(&new.thread_id)
        .bind(&new.thread_id)
        .bind(&new.thread_id)
        .fetch_one(&mut *conn)
        .await;

        match result {
            Ok(row) => {
                sqlx::query("COMMIT").execute(&mut *conn).await?;
                Ok(row)
            }
            Err(e) => {
                let _ = sqlx::query("ROLLBACK").execute(&mut *conn).await;
                if is_unique_client_message_id_error(&e) {
                    Err(DuplicateClientMessageId.into())
                } else {
                    Err(e.into())
                }
            }
        }
    }

    pub async fn delete_message(&self, id: i64) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM messages WHERE id = ?")
            .bind(id)
            .execute(self.pool())
            .await
            .map_err(Into::into)
            .map(|_| ())
    }

    pub async fn list_messages_since(
        &self,
        thread_id: &str,
        since_seq: i64,
        limit: i64,
    ) -> anyhow::Result<Vec<MessageRow>> {
        let sql = format!(
            "WITH cte AS ({SELECT_TRUNCATED} WHERE thread_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?)\nSELECT * FROM cte ORDER BY id ASC"
        );
        sqlx::query_as::<_, MessageRow>(&sql)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_PARTS_BUDGET)
            .bind(thread_id)
            .bind(since_seq)
            .bind(limit)
            .fetch_all(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn list_messages(&self, thread_id: &str) -> anyhow::Result<Vec<MessageRow>> {
        let sql = format!(
            "WITH cte AS ({SELECT_TRUNCATED} WHERE thread_id = ? ORDER BY id ASC LIMIT 10000)\nSELECT * FROM cte ORDER BY id ASC"
        );
        sqlx::query_as::<_, MessageRow>(&sql)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_PARTS_BUDGET)
            .bind(thread_id)
            .fetch_all(self.pool())
            .await
            .map_err(Into::into)
    }

    /// Recent messages with `content` capped to `max_chars` per row, for
    /// building thread-reference transcripts without reading full bodies.
    /// `content_length` still reports the true length so callers can tell a
    /// truncated excerpt from a complete message.
    pub async fn list_recent_message_excerpts(
        &self,
        thread_id: &str,
        limit: i64,
        max_chars: i64,
    ) -> anyhow::Result<Vec<MessageRow>> {
        sqlx::query_as::<_, MessageRow>(
            "SELECT
                id,
                thread_id,
                role,
                SUBSTR(content, 1, ?) AS content,
                NULL AS thinking,
                NULL AS parts,
                '' AS attachments,
                model,
                client_message_id,
                created_at,
                turn_id,
                seq,
                content_length,
                parts_length
            FROM (
                SELECT * FROM messages
                WHERE thread_id = ?
                ORDER BY id DESC
                LIMIT ?
            ) ORDER BY id ASC",
        )
        .bind(max_chars)
        .bind(thread_id)
        .bind(limit)
        .fetch_all(self.pool())
        .await
        .map_err(Into::into)
    }

    pub async fn count_messages(&self, thread_id: &str) -> anyhow::Result<i64> {
        let row: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM messages WHERE thread_id = ?")
            .bind(thread_id)
            .fetch_one(self.pool())
            .await?;
        Ok(row.0)
    }

    pub async fn get_message(
        &self,
        thread_id: &str,
        id: i64,
    ) -> anyhow::Result<Option<MessageRow>> {
        let sql = format!(
            "WITH cte AS ({SELECT_TRUNCATED} WHERE thread_id = ? AND id = ?)\nSELECT * FROM cte ORDER BY id ASC"
        );
        sqlx::query_as::<_, MessageRow>(&sql)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_CHAR_BUDGET)
            .bind(MESSAGE_PARTS_BUDGET)
            .bind(thread_id)
            .bind(id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn get_message_full(
        &self,
        thread_id: &str,
        id: i64,
    ) -> anyhow::Result<Option<MessageRow>> {
        sqlx::query_as::<_, MessageRow>("SELECT * FROM messages WHERE thread_id = ? AND id = ?")
            .bind(thread_id)
            .bind(id)
            .fetch_optional(self.pool())
            .await
            .map_err(Into::into)
    }

    pub async fn max_seq(&self, thread_id: &str) -> anyhow::Result<i64> {
        let row: (i64,) =
            sqlx::query_as("SELECT COALESCE(MAX(seq), 0) FROM messages WHERE thread_id = ?")
                .bind(thread_id)
                .fetch_one(self.pool())
                .await?;
        Ok(row.0)
    }

    /// Returns a chunk of a single message's content.
    pub async fn get_message_chunk(
        &self,
        thread_id: &str,
        id: i64,
        offset: i64,
        limit: i64,
    ) -> anyhow::Result<Option<(MessageRow, i64)>> {
        let row: Option<(String, i64)> = sqlx::query_as(
            "SELECT SUBSTR(content, ?, ?) AS content, content_length AS total
             FROM messages WHERE thread_id = ? AND id = ?",
        )
        .bind(offset + 1)
        .bind(limit)
        .bind(thread_id)
        .bind(id)
        .fetch_optional(self.pool())
        .await?;

        let Some((content, total)) = row else {
            return Ok(None);
        };

        let meta = sqlx::query_as::<_, MessageRow>(
            "SELECT id, thread_id, role, ? AS content,
                CASE WHEN thinking IS NOT NULL AND length(thinking) > ? THEN NULL ELSE thinking END AS thinking,
                NULL AS parts, attachments, model, client_message_id, created_at, turn_id, seq, content_length, 0 AS parts_length
             FROM messages WHERE thread_id = ? AND id = ?",
        )
        .bind(content)
        .bind(MESSAGE_CHAR_BUDGET)
        .bind(thread_id)
        .bind(id)
        .fetch_optional(self.pool())
        .await?;

        Ok(meta.map(|m| (m, total)))
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

        let mut sql = format!("WITH cte AS (\n{SELECT_TRUNCATED}\n",);

        match (before_id, after_id) {
            (Some(before), _) => {
                sql.push_str(
                    "  WHERE thread_id = ? AND id < ?\n  ORDER BY id DESC LIMIT ?\n)\nSELECT * FROM cte ORDER BY id ASC",
                );
                query_paginated(&sql, thread_id)
                    .bind(before)
                    .bind(limit)
                    .fetch_all(self.pool())
                    .await
            }
            (None, Some(after)) => {
                sql.push_str(
                    "  WHERE thread_id = ? AND id > ?\n  ORDER BY id ASC LIMIT ?\n)\nSELECT * FROM cte ORDER BY id ASC",
                );
                query_paginated(&sql, thread_id)
                    .bind(after)
                    .bind(limit)
                    .fetch_all(self.pool())
                    .await
            }
            (None, None) => {
                sql.push_str(
                    "  WHERE thread_id = ?\n  ORDER BY id DESC LIMIT ?\n)\nSELECT * FROM cte ORDER BY id ASC",
                );
                query_paginated(&sql, thread_id)
                    .bind(limit)
                    .fetch_all(self.pool())
                    .await
            }
        }
        .map_err(Into::into)
    }

    /// Paginate by user-anchored turns.
    ///
    /// A turn is one user message plus all non-user messages that follow until
    /// the next user message. `turn_limit` counts user-anchored turns; the
    /// subagent messages between them ride along. The returned list is ordered
    /// by message id (ascending). The `before_cursor` is exclusive.
    pub async fn list_messages_turn_windowed(
        &self,
        thread_id: &str,
        before_cursor: Option<TurnCursor>,
        turn_limit: i64,
    ) -> anyhow::Result<(Vec<MessageRow>, i64, Option<TurnCursor>, bool)> {
        if turn_limit <= 0 {
            return Ok((
                Vec::new(),
                self.count_messages(thread_id).await?,
                before_cursor,
                false,
            ));
        }

        let mut sql = format!("WITH cte AS (\n{SELECT_TRUNCATED}\n  WHERE thread_id = ? AND (\n",);

        // Select the turn_limit most recent distinct turn ids older than the cursor.
        sql.push_str(
            "    turn_id IN (\n      SELECT DISTINCT turn_id FROM messages\n      WHERE thread_id = ? AND (? IS NULL OR turn_id < ?)\n      ORDER BY turn_id DESC\n      LIMIT ?\n    )\n",
        );

        // If we are resuming from the middle of a turn, include the older part
        // of that same turn as well.
        sql.push_str(
            "    OR (? IS NOT NULL AND turn_id = ? AND id < ?)\n  )\n  ORDER BY id DESC\n  LIMIT ?\n)\nSELECT * FROM cte ORDER BY id ASC",
        );

        let before_turn: Option<i64> = before_cursor.map(|c| c.turn_id);
        let before_id: Option<i64> = before_cursor.map(|c| c.id);

        let rows: Vec<MessageRow> = query_paginated(&sql, thread_id)
            .bind(thread_id)
            .bind(before_turn)
            .bind(before_turn)
            .bind(turn_limit)
            .bind(before_turn)
            .bind(before_turn)
            .bind(before_id)
            .bind(MAX_RAW_TURNS_PER_PAGE)
            .fetch_all(self.pool())
            .await?;

        let total = self.count_messages(thread_id).await?;

        if rows.is_empty() {
            return Ok((Vec::new(), total, before_cursor, false));
        }

        let oldest = rows.first().unwrap();
        let next_cursor = TurnCursor {
            turn_id: oldest.turn_id,
            id: oldest.id,
        };

        let has_more = self
            .has_messages_older_than(thread_id, &next_cursor)
            .await?;

        Ok((rows, total, Some(next_cursor), has_more))
    }

    async fn has_messages_older_than(
        &self,
        thread_id: &str,
        cursor: &TurnCursor,
    ) -> anyhow::Result<bool> {
        let row: (i64,) = sqlx::query_as(
            "SELECT EXISTS(
                SELECT 1 FROM messages
                WHERE thread_id = ? AND (turn_id < ? OR (turn_id = ? AND id < ?))
            )",
        )
        .bind(thread_id)
        .bind(cursor.turn_id)
        .bind(cursor.turn_id)
        .bind(cursor.id)
        .fetch_one(self.pool())
        .await?;
        Ok(row.0 != 0)
    }
}

fn is_unique_client_message_id_error(e: &sqlx::Error) -> bool {
    if let Some(db) = e.as_database_error() {
        if let Some(code) = db.code() {
            if code == "2067" || code == "1555" {
                return true;
            }
        }
        let msg = db.message();
        if !msg.is_empty() {
            return msg.contains("UNIQUE constraint failed") && msg.contains("client_message_id");
        }
    }
    false
}

const SELECT_TRUNCATED: &str = "SELECT
    id,
    thread_id,
    role,
    CASE
        WHEN content_length > ? THEN SUBSTR(content, 1, ?)
        ELSE content
    END AS content,
    CASE
        WHEN thinking IS NOT NULL AND length(thinking) > ? THEN SUBSTR(thinking, 1, ?)
        ELSE thinking
    END AS thinking,
    CASE
        WHEN parts_length IS NOT NULL AND parts_length > ? THEN NULL
        ELSE parts
    END AS parts,
    attachments,
    model,
    client_message_id,
    created_at,
    turn_id,
    seq,
    content_length,
    parts_length
FROM messages";

fn query_paginated<'q>(
    sql: &'q str,
    thread_id: &'q str,
) -> sqlx::query::QueryAs<'q, sqlx::Sqlite, MessageRow, sqlx::sqlite::SqliteArguments<'q>> {
    sqlx::query_as::<_, MessageRow>(sql)
        .bind(MESSAGE_CHAR_BUDGET)
        .bind(MESSAGE_CHAR_BUDGET)
        .bind(MESSAGE_CHAR_BUDGET)
        .bind(MESSAGE_CHAR_BUDGET)
        .bind(MESSAGE_PARTS_BUDGET)
        .bind(thread_id)
}
