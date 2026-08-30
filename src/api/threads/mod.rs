//! Thread + chat API routes.
//!
//! A thread maps to a devin-cli session. The first `send` starts the session
//! (`provider.start`); subsequent sends continue it (`provider.send`). Every
//! user message and assistant reply is persisted in the `messages` table.

pub(crate) mod permissions;
pub(crate) mod persistence;
pub(crate) mod plan;
pub(crate) mod routes;
pub(crate) mod runs;
pub(crate) mod send;
pub(crate) mod stream;

use axum::routing::{get, post, Router};
use serde::{Deserialize, Serialize};

use crate::db::messages::{MESSAGE_CHAR_BUDGET, MESSAGE_PARTS_BUDGET};
use crate::db::{MessageRow, ThreadRow};
use crate::providers::{collect_text, collect_thinking, MessagePart};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/threads", get(routes::list).post(routes::create))
        .route("/api/threads/runs", get(runs::list_runs))
        .route(
            "/api/threads/:id",
            get(routes::get_one)
                .patch(routes::rename)
                .delete(routes::delete),
        )
        .route("/api/threads/:id/pin", post(routes::pin))
        .route("/api/threads/:id/messages", get(routes::list_messages))
        .route(
            "/api/threads/:id/messages/stream",
            get(stream::message_stream),
        )
        .route(
            "/api/threads/:id/messages/:message_id",
            get(routes::get_message),
        )
        .route(
            "/api/threads/:id/messages/:message_id/full",
            get(routes::get_message_full),
        )
        .route("/api/threads/:id/send", post(send::send))
        .route("/api/threads/:id/send/stream", post(send::send_stream))
        .route("/api/threads/:id/run", get(runs::get_run))
        .route("/api/threads/:id/stop", post(runs::stop))
        .route("/api/threads/:id/events", get(runs::events))
        .route(
            "/api/threads/:id/permission/:request_id",
            post(permissions::respond_permission),
        )
        .route(
            "/api/threads/:id/ask/:request_id",
            post(permissions::respond_ask),
        )
        .route("/api/threads/:id/project", get(plan::get_project_path))
        .route("/api/threads/:id/plan", get(plan::get_plan))
}

#[derive(Debug, Serialize)]
pub struct ThreadOut {
    pub id: String,
    pub title: String,
    pub project_id: i64,
    pub thread_group_id: Option<i64>,
    pub devin_session_id: Option<String>,
    pub model: String,
    pub permission_mode: String,
    pub permissions: Option<String>,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    pub pinned: bool,
    pub created_at: String,
    pub updated_at: String,
}

impl From<ThreadRow> for ThreadOut {
    fn from(t: ThreadRow) -> Self {
        Self {
            id: t.id,
            title: t.title,
            project_id: t.project_id.unwrap_or(0),
            thread_group_id: t.thread_group_id,
            devin_session_id: t.devin_session_id,
            model: t.model,
            permission_mode: t.permission_mode,
            permissions: t.permissions,
            branch: t.branch,
            worktree_path: t.worktree_path,
            pinned: t.pinned,
            created_at: t.created_at,
            updated_at: t.updated_at,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct MessageOut {
    pub id: i64,
    pub role: String,
    pub content: String,
    pub thinking: Option<String>,
    pub parts: Vec<MessagePart>,
    pub attachments: serde_json::Value,
    pub model: String,
    pub created_at: String,
    pub turn_id: i64,
    pub seq: i64,
    pub truncated: bool,
    pub total_chars: Option<usize>,
    pub truncated_at: Option<usize>,
}

impl From<MessageRow> for MessageOut {
    fn from(m: MessageRow) -> Self {
        let attachments: serde_json::Value =
            serde_json::from_str(&m.attachments).unwrap_or(serde_json::json!([]));

        let content_truncated = m.content_length > MESSAGE_CHAR_BUDGET;

        let parts: Vec<MessagePart> = m
            .parts
            .as_deref()
            .and_then(|s| serde_json::from_str::<Vec<MessagePart>>(s).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|p| !content_truncated || matches!(p, MessagePart::ToolCall { .. }))
            .collect();

        let (content, thinking) = if content_truncated || parts.is_empty() {
            (
                m.content.clone(),
                m.thinking.clone().filter(|s| !s.is_empty()),
            )
        } else {
            let content = collect_text(&parts);
            let thinking = collect_thinking(&parts);
            let thinking = (!thinking.is_empty()).then_some(thinking);
            (content, thinking)
        };

        let content_chars = content.chars().count() as i64;
        let truncated = content_chars < m.content_length
            || (m.parts.is_none() && m.parts_length.map_or(false, |l| l > MESSAGE_PARTS_BUDGET));
        let (total_chars, truncated_at) = if truncated {
            let total = (m.content_length + m.parts_length.unwrap_or(0)) as usize;
            (Some(total), Some(content_chars as usize))
        } else {
            (None, None)
        };

        Self {
            id: m.id,
            role: m.role,
            content,
            thinking,
            parts,
            attachments,
            model: m.model,
            created_at: m.created_at,
            turn_id: m.turn_id,
            seq: m.seq,
            truncated,
            total_chars,
            truncated_at,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateThread {
    pub project_id: i64,
    pub title: Option<String>,
    pub thread_group_id: Option<i64>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    pub permissions: Option<String>,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct GetThread {
    pub include_messages: Option<String>,
    pub limit: Option<i64>,
    pub turn_limit: Option<i64>,
    pub before_cursor: Option<String>,
}

impl Default for GetThread {
    fn default() -> Self {
        Self {
            include_messages: None,
            limit: Some(50),
            turn_limit: None,
            before_cursor: None,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct ListMessages {
    pub before_id: Option<i64>,
    pub after_id: Option<i64>,
    pub limit: Option<i64>,
    pub turn_limit: Option<i64>,
    pub before_cursor: Option<String>,
}

impl Default for ListMessages {
    fn default() -> Self {
        Self {
            before_id: None,
            after_id: None,
            limit: Some(50),
            turn_limit: None,
            before_cursor: None,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct MessageChunkQuery {
    pub offset: Option<i64>,
    pub limit: Option<i64>,
}

impl Default for MessageChunkQuery {
    fn default() -> Self {
        Self {
            offset: Some(0),
            limit: Some(crate::db::messages::MESSAGE_CHAR_BUDGET),
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct PinThread {
    pub pinned: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateThread {
    pub title: Option<String>,
    /// Distinguish between:
    ///   - field absent: don't change group
    ///   - field null: ungroup (set thread_group_id to NULL)
    ///   - field is a number: move to that group
    #[serde(default, deserialize_with = "deserialize_optional_field")]
    pub thread_group_id: Option<Option<i64>>,
    pub model: Option<String>,
    pub permission_mode: Option<String>,
    /// Distinguish between:
    ///   - field absent: don't change permissions
    ///   - field null: clear permissions
    ///   - field string: set permissions
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub permissions: Option<Option<String>>,
    /// Distinguish between absent and null for optional Git context.
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub branch: Option<Option<String>>,
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    pub worktree_path: Option<Option<String>>,
}

/// Custom deserializer that maps `null` -> `Some(None)` and a number -> `Some(Some(n))`.
/// With `#[serde(default)]`, an absent field -> `None` (outer).
fn deserialize_optional_field<'de, D>(deserializer: D) -> Result<Option<Option<i64>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<i64>::deserialize(deserializer)?;
    Ok(Some(opt))
}

fn deserialize_optional_string<'de, D>(deserializer: D) -> Result<Option<Option<String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt = Option::<String>::deserialize(deserializer)?;
    Ok(Some(opt))
}

#[cfg(test)]
mod tests {
    use super::{MessageOut, ThreadOut};
    use crate::db::{MessageRow, ThreadRow};
    use crate::providers::MessagePart;

    #[test]
    fn thread_out_preserves_thread_fields() {
        let row = ThreadRow {
            id: "th-1".into(),
            user_id: 1,
            title: "My thread".into(),
            devin_session_id: None,
            model: "glm-5-2".into(),
            permission_mode: "normal".into(),
            permissions: None,
            created_at: "2024-01-01T00:00:00Z".into(),
            updated_at: "2024-01-01T00:00:00Z".into(),
            thread_group_id: None,
            project_id: Some(7),
            branch: None,
            worktree_path: None,
            pinned: true,
        };
        let out = ThreadOut::from(row);
        assert_eq!(out.id, "th-1");
        assert_eq!(out.title, "My thread");
        assert_eq!(out.project_id, 7);
        assert!(out.pinned);
    }

    #[test]
    fn message_out_collects_text_and_thinking_parts() {
        let parts_json = serde_json::to_string(&[
            MessagePart::text("hello "),
            MessagePart::thinking("hmm"),
            MessagePart::text("world"),
        ])
        .unwrap();
        let row = MessageRow {
            id: 1,
            thread_id: "th-1".into(),
            role: "assistant".into(),
            content: "ignored".into(),
            thinking: Some("ignored".into()),
            parts: Some(parts_json.clone()),
            attachments: "[]".into(),
            model: "glm-5-2".into(),
            created_at: "2024-01-01T00:00:00Z".into(),
            turn_id: 1,
            seq: 1,
            content_length: 7,
            parts_length: Some(parts_json.len() as i64),
        };
        let out = MessageOut::from(row);
        assert_eq!(out.content, "hello world");
        assert_eq!(out.thinking, Some("hmm".into()));
        assert_eq!(out.parts.len(), 3);
    }
}
