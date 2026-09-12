//! Thread references: threads the user dragged from the sidebar into the
//! composer so the model sees their recent history as context.
//!
//! The frontend sends thread ids in the `referenced_thread_ids` multipart
//! field (a JSON array of strings). Each id is resolved against the caller's
//! threads, the tail of its message history is rendered as a transcript, and
//! the transcripts are appended to the prompt sent to the provider. The
//! stored user message keeps only the user's own text; the references show
//! up as chips in its attachment metadata.

use std::collections::HashSet;

use crate::db::{MessageRow, ThreadRow};
use crate::AppState;

use super::send::SendInput;

/// Maximum number of thread references accepted per message.
const MAX_THREAD_REFS: usize = 8;
/// Maximum length of a single referenced thread id.
const MAX_THREAD_ID_LEN: usize = 128;
/// Most recent messages pulled from each referenced thread.
const THREAD_REF_MESSAGES: i64 = 20;
/// Total transcript characters shared across all referenced threads.
const THREAD_REF_CONTEXT_BUDGET: usize = 4000;
/// A single message never contributes more than this to the transcript.
const THREAD_REF_MESSAGE_MAX_CHARS: usize = 1000;

/// A thread the user referenced, with its recent history ready to render.
#[derive(Debug, Clone)]
pub(crate) struct ThreadRef {
    pub title: String,
    /// Oldest-to-newest tail of the thread's history (at most
    /// `THREAD_REF_MESSAGES` rows).
    pub messages: Vec<MessageRow>,
}

/// Parse the `referenced_thread_ids` multipart field: a JSON array of
/// thread id strings. Ids are deduplicated in arrival order.
pub(crate) fn parse_referenced_thread_ids(raw: &str) -> Result<Vec<String>, String> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| "invalid referenced_thread_ids".to_string())?;
    let items = value
        .as_array()
        .ok_or_else(|| "invalid referenced_thread_ids".to_string())?;
    if items.len() > MAX_THREAD_REFS {
        return Err(format!(
            "too many referenced threads (max {MAX_THREAD_REFS})"
        ));
    }
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let id = item
            .as_str()
            .ok_or_else(|| "invalid referenced_thread_ids".to_string())?
            .trim();
        if id.is_empty() || id.chars().count() > MAX_THREAD_ID_LEN {
            return Err("invalid referenced_thread_ids".to_string());
        }
        if seen.insert(id.to_string()) {
            out.push(id.to_string());
        }
    }
    Ok(out)
}

/// Resolve `input.referenced_thread_ids` into `input.thread_refs`, loading
/// the recent messages of each thread the caller owns. Missing threads,
/// threads owned by other users, and the current thread are dropped
/// silently. Each surviving reference is recorded in `input.att_meta` so it
/// renders as a chip in the message history.
pub(crate) async fn resolve_thread_refs(
    state: &AppState,
    user_id: i64,
    thread: &ThreadRow,
    input: &mut SendInput,
) {
    // Dedupe and cap here too: a multipart body can carry the field more
    // than once, bypassing the per-field limits in the parser.
    let mut seen = HashSet::new();
    let ids: Vec<String> = std::mem::take(&mut input.referenced_thread_ids)
        .into_iter()
        .filter(|id| seen.insert(id.clone()))
        .take(MAX_THREAD_REFS)
        .collect();
    for id in ids {
        if id == thread.id {
            continue;
        }
        // get_thread filters by user, so a miss covers both unknown ids and
        // threads owned by someone else.
        let Ok(Some(referenced)) = state.db.get_thread(&id, user_id).await else {
            continue;
        };
        let messages = state
            .db
            .list_recent_message_excerpts(
                &id,
                THREAD_REF_MESSAGES,
                THREAD_REF_MESSAGE_MAX_CHARS as i64,
            )
            .await
            .unwrap_or_default();
        input.att_meta.push(serde_json::json!({
            "filename": referenced.title,
            "mime": "application/x-devinorium-thread",
            "size": 0,
            "kind": "thread",
            "thread_id": id,
        }));
        input.thread_refs.push(ThreadRef {
            title: referenced.title,
            messages,
        });
    }
}

/// Render one referenced thread's transcript under `budget` characters.
/// Messages are collected newest-first so a tight budget keeps the freshest
/// context, then flipped back into conversation order.
fn transcript(messages: &[MessageRow], budget: usize) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut used = 0usize;
    for m in messages.iter().rev() {
        let content = m.content.trim();
        if content.is_empty() {
            continue;
        }
        let cap = THREAD_REF_MESSAGE_MAX_CHARS.min(budget.saturating_sub(used));
        if cap == 0 {
            break;
        }
        let truncated =
            content.chars().count() > cap || m.content_length as usize > content.chars().count();
        let text: String = content.chars().take(cap).collect();
        let line = format!("{}: {}{}", m.role, text, if truncated { "…" } else { "" });
        used += line.chars().count();
        lines.push(line);
    }
    lines.reverse();
    lines.join("\n")
}

/// Build the prompt sent to the provider: the user's text plus a context
/// block with a transcript of each referenced thread's recent history.
pub(crate) fn prompt_with_thread_refs(prompt: &str, refs: &[ThreadRef]) -> String {
    if refs.is_empty() {
        return prompt.to_string();
    }
    let mut out =
        String::with_capacity(prompt.len() + THREAD_REF_CONTEXT_BUDGET + refs.len() * 64 + 64);
    let trimmed = prompt.trim_end();
    if !trimmed.is_empty() {
        out.push_str(trimmed);
        out.push_str("\n\n");
    }
    out.push_str("The user referenced these threads for context:");
    let mut budget = THREAD_REF_CONTEXT_BUDGET;
    for r in refs {
        out.push_str("\n\nThread \"");
        out.push_str(&r.title);
        out.push_str("\":");
        let text = transcript(&r.messages, budget);
        if text.is_empty() {
            let has_content = r.messages.iter().any(|m| !m.content.trim().is_empty());
            out.push_str(if has_content {
                " (omitted)"
            } else {
                " (no messages)"
            });
        } else {
            budget = budget.saturating_sub(text.chars().count());
            out.push('\n');
            out.push_str(&text);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(role: &str, content: &str) -> MessageRow {
        MessageRow {
            id: 0,
            thread_id: "t".into(),
            role: role.into(),
            content: content.into(),
            thinking: None,
            parts: None,
            attachments: "[]".into(),
            model: String::new(),
            client_message_id: None,
            created_at: String::new(),
            turn_id: 0,
            seq: 0,
            content_length: content.len() as i64,
            parts_length: None,
        }
    }

    #[test]
    fn parse_referenced_thread_ids_accepts_string_array() {
        let ids = parse_referenced_thread_ids(r#"["a","b","a"," c "]"#).unwrap();
        assert_eq!(ids, ["a", "b", "c"]);
    }

    #[test]
    fn parse_referenced_thread_ids_rejects_malformed() {
        assert!(parse_referenced_thread_ids("not json").is_err());
        assert!(parse_referenced_thread_ids(r#"{"id":"a"}"#).is_err());
        assert!(parse_referenced_thread_ids(r#"[1]"#).is_err());
        assert!(parse_referenced_thread_ids(r#"[""]"#).is_err());
        let many = vec!["x"; MAX_THREAD_REFS + 1];
        assert!(parse_referenced_thread_ids(&serde_json::to_string(&many).unwrap()).is_err());
        let long = serde_json::to_string(&["x".repeat(MAX_THREAD_ID_LEN + 1)]).unwrap();
        assert!(parse_referenced_thread_ids(&long).is_err());
    }

    #[test]
    fn transcript_renders_roles_oldest_to_newest() {
        let messages = vec![
            msg("user", "first"),
            msg("assistant", "reply one"),
            msg("user", "second"),
        ];
        let t = transcript(&messages, THREAD_REF_CONTEXT_BUDGET);
        assert_eq!(t, "user: first\nassistant: reply one\nuser: second");
    }

    #[test]
    fn transcript_skips_empty_and_truncates_long_messages() {
        let long = "x".repeat(THREAD_REF_MESSAGE_MAX_CHARS + 50);
        let messages = vec![msg("user", ""), msg("assistant", &long)];
        let t = transcript(&messages, THREAD_REF_CONTEXT_BUDGET);
        assert_eq!(
            t.chars().count(),
            "assistant: ".chars().count() + THREAD_REF_MESSAGE_MAX_CHARS + 1
        );
        assert!(t.ends_with('…'));
        assert!(!t.contains("user:"));
    }

    #[test]
    fn transcript_keeps_newest_messages_when_budget_is_tight() {
        let messages = vec![
            msg("user", "old message"),
            msg("assistant", "older reply"),
            msg("user", "newest message"),
        ];
        let t = transcript(&messages, 20);
        assert_eq!(t, "user: newest message");
    }

    #[test]
    fn prompt_with_thread_refs_appends_transcripts() {
        let refs = vec![
            ThreadRef {
                title: "Alpha".into(),
                messages: vec![msg("user", "hi"), msg("assistant", "hello")],
            },
            ThreadRef {
                title: "Empty".into(),
                messages: vec![],
            },
        ];
        let out = prompt_with_thread_refs("fix the bug", &refs);
        assert!(out.starts_with("fix the bug\n\n"));
        assert!(out.contains("The user referenced these threads for context:"));
        assert!(out.contains("Thread \"Alpha\":\nuser: hi\nassistant: hello"));
        assert!(out.contains("Thread \"Empty\": (no messages)"));
        assert_eq!(prompt_with_thread_refs("hi", &[]), "hi");
    }
}
