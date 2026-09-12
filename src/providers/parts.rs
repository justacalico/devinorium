use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::ToolCallEvent;
use crate::plan;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessagePart {
    Text {
        content: String,
    },
    Thinking {
        content: String,
    },
    #[serde(rename = "tool_call")]
    ToolCall {
        #[serde(flatten)]
        payload: ToolCallEvent,
    },
}

impl MessagePart {
    pub fn text(content: impl Into<String>) -> Self {
        Self::Text {
            content: content.into(),
        }
    }

    pub fn thinking(content: impl Into<String>) -> Self {
        Self::Thinking {
            content: content.into(),
        }
    }

    pub fn tool_call(payload: ToolCallEvent) -> Self {
        Self::ToolCall { payload }
    }

    pub fn tool_id(&self) -> Option<&str> {
        match self {
            Self::ToolCall { payload } => Some(&payload.id),
            _ => None,
        }
    }

    pub fn text_content(&self) -> Option<&str> {
        match self {
            Self::Text { content } => Some(content.as_str()),
            _ => None,
        }
    }

    pub fn thinking_content(&self) -> Option<&str> {
        match self {
            Self::Thinking { content } => Some(content.as_str()),
            _ => None,
        }
    }

    /// Return a copy with `<proposed_plan>` and `<update_plan>` blocks removed
    /// from text and thinking content. Tool-call parts are unchanged.
    pub fn strip_plan_markup(self) -> Self {
        match self {
            Self::Text { content } => Self::Text {
                content: plan::strip_plan_markup(&content),
            },
            Self::Thinking { content } => Self::Thinking {
                content: plan::strip_plan_markup(&content),
            },
            Self::ToolCall { .. } => self,
        }
    }
}

#[derive(Debug, Clone)]
pub enum PartEvent {
    New(MessagePart),
    Update(MessagePart),
}

impl PartEvent {
    pub fn part(&self) -> &MessagePart {
        match self {
            Self::New(p) | Self::Update(p) => p,
        }
    }

    pub fn is_update(&self) -> bool {
        matches!(self, Self::Update(_))
    }
}

pub type PartCallback = Arc<dyn Fn(PartEvent) + Send + Sync + 'static>;

pub fn collect_text(parts: &[MessagePart]) -> String {
    parts
        .iter()
        .filter_map(|p| match p {
            MessagePart::Text { content } => Some(content.as_str()),
            _ => None,
        })
        .collect()
}

pub fn collect_thinking(parts: &[MessagePart]) -> String {
    parts
        .iter()
        .filter_map(|p| match p {
            MessagePart::Thinking { content } => Some(content.as_str()),
            _ => None,
        })
        .collect()
}

/// Coalesce consecutive text and thinking parts, then strip any plan markup.
///
/// This handles plan blocks that are split across multiple streamed parts while
/// keeping tool-call parts in place and preserving the overall message order.
/// Tool calls still marked pending/in-progress when the run ends are clamped
/// to `failed`: the run is over, so they can never finish.
pub fn strip_plan_markup_from_parts(parts: Vec<MessagePart>) -> Vec<MessagePart> {
    let mut out = Vec::with_capacity(parts.len());
    let mut text_buf = String::new();
    let mut thinking_buf = String::new();

    for part in parts {
        match part {
            MessagePart::Text { content } => {
                if content.trim().is_empty() {
                    // Transparent when no text run is open: whitespace must not
                    // flush the thinking buffer and split a run (which could
                    // break plan markup spanning the boundary).
                    if !text_buf.is_empty() {
                        text_buf.push_str(&content);
                    }
                    continue;
                }
                flush_thinking(&mut thinking_buf, &mut out);
                text_buf.push_str(&content);
            }
            MessagePart::Thinking { content } => {
                if content.trim().is_empty() {
                    if !thinking_buf.is_empty() {
                        thinking_buf.push_str(&content);
                    }
                    continue;
                }
                flush_text(&mut text_buf, &mut out);
                push_thinking_chunk(&mut thinking_buf, &content);
            }
            MessagePart::ToolCall { mut payload } => {
                flush_text(&mut text_buf, &mut out);
                flush_thinking(&mut thinking_buf, &mut out);
                if payload.status != "completed" && payload.status != "failed" {
                    payload.status = "failed".into();
                }
                out.push(MessagePart::ToolCall { payload });
            }
        }
    }
    flush_text(&mut text_buf, &mut out);
    flush_thinking(&mut thinking_buf, &mut out);
    out
}

/// Append a streamed thinking chunk to the coalescing buffer. When the chunk
/// clearly starts a new utterance (the buffered text ends a sentence and the
/// chunk starts like a new one) the boundary is kept as a blank line so
/// separate narration runs still render as distinct paragraphs after merging.
/// Thinking renders as plain text, so the injected break is display-only.
fn push_thinking_chunk(buf: &mut String, content: &str) {
    if starts_new_utterance(buf, content) {
        let trimmed_len = buf.trim_end().len();
        buf.truncate(trimmed_len);
        buf.push_str("\n\n");
        buf.push_str(content.trim_start());
    } else {
        buf.push_str(content);
    }
}

fn starts_new_utterance(prev: &str, next: &str) -> bool {
    let Some(last) = prev.trim_end().chars().last() else {
        return false;
    };
    if !matches!(last, '.' | '!' | '?') {
        return false;
    }
    let Some(first) = next.trim_start().chars().next() else {
        return false;
    };
    if first == '<' {
        return false;
    }
    first.is_ascii_uppercase() || matches!(first, '"' | '\'' | '`' | '(' | '*' | '#' | '-')
}

fn flush_text(buf: &mut String, out: &mut Vec<MessagePart>) {
    if !buf.is_empty() {
        let content = plan::strip_plan_markup(buf);
        buf.clear();
        if !content.is_empty() {
            out.push(MessagePart::text(content));
        }
    }
}

fn flush_thinking(buf: &mut String, out: &mut Vec<MessagePart>) {
    if !buf.is_empty() {
        let content = plan::strip_plan_markup(buf);
        buf.clear();
        if !content.is_empty() {
            out.push(MessagePart::thinking(content));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::ToolCallEvent;
    use super::*;

    #[test]
    fn text_and_thinking_round_trip() {
        let parts = vec![
            MessagePart::text("hello "),
            MessagePart::thinking("hmm"),
            MessagePart::text("world"),
        ];
        let json = serde_json::to_string(&parts).unwrap();
        let decoded: Vec<MessagePart> = serde_json::from_str(&json).unwrap();
        assert_eq!(parts, decoded);
        assert_eq!(collect_text(&parts), "hello world");
        assert_eq!(collect_thinking(&parts), "hmm");
    }

    #[test]
    fn tool_call_flattens_payload_fields() {
        let part = MessagePart::tool_call(ToolCallEvent {
            id: "tc-1".into(),
            title: "Read file".into(),
            kind: "read".into(),
            status: "completed".into(),
            command: Some("cat file.txt".into()),
            output: Some("hello".into()),
            output_preview: Some("hello".into()),
            changed_files: vec!["file.txt".into()],
            diffs: vec![],
        });
        let json = serde_json::to_string(&part).unwrap();
        assert!(json.contains("\"type\":\"tool_call\""));
        assert!(json.contains("\"id\":\"tc-1\""));
        let decoded: MessagePart = serde_json::from_str(&json).unwrap();
        assert_eq!(part, decoded);
    }

    #[test]
    fn part_event_picks_right_payload() {
        let p = MessagePart::text("x");
        let ev = PartEvent::Update(p.clone());
        assert_eq!(ev.part(), &p);
        assert!(ev.is_update());
    }

    #[test]
    fn strip_plan_markup_cleans_text_and_thinking() {
        let text =
            MessagePart::text(r#"<update_plan explanation="Build"><step>A</step></update_plan>"#)
                .strip_plan_markup();
        assert_eq!(text.text_content(), Some(""));

        let thinking =
            MessagePart::thinking("Plan: <proposed_plan><step>X</step></proposed_plan> done")
                .strip_plan_markup();
        assert_eq!(thinking.thinking_content(), Some("Plan:  done"));

        let tool = MessagePart::tool_call(ToolCallEvent {
            id: "tc-1".into(),
            title: "Read".into(),
            kind: "read".into(),
            status: "completed".into(),
            command: None,
            output: None,
            output_preview: None,
            changed_files: vec![],
            diffs: vec![],
        });
        assert_eq!(tool.clone().strip_plan_markup(), tool);
    }

    #[test]
    fn strip_plan_markup_from_parts_coalesces_split_blocks() {
        let parts = vec![
            MessagePart::text("<update_plan explanation=\"Build\">"),
            MessagePart::text("<step status=\"completed\">A</step>"),
            MessagePart::text("<step status=\"in_progress\">B</step>"),
            MessagePart::text("</update_plan>"),
            MessagePart::tool_call(ToolCallEvent {
                id: "tc-1".into(),
                title: "Read".into(),
                kind: "read".into(),
                status: "completed".into(),
                command: None,
                output: None,
                output_preview: None,
                changed_files: vec![],
                diffs: vec![],
            }),
            MessagePart::text("Done."),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 2);
        assert_eq!(stripped[0].tool_id(), Some("tc-1"));
        assert_eq!(collect_text(&stripped), "Done.");
        assert!(collect_thinking(&stripped).is_empty());
    }

    #[test]
    fn strip_plan_markup_merges_token_fragments() {
        let parts = vec![
            MessagePart::thinking("The"),
            MessagePart::thinking(" user wants me"),
            MessagePart::thinking(" to rebase the branch"),
            MessagePart::thinking(", so I should check the status first"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(
            stripped[0].thinking_content(),
            Some("The user wants me to rebase the branch, so I should check the status first")
        );
    }

    #[test]
    fn strip_plan_markup_breaks_at_sentence_boundary() {
        let parts = vec![
            MessagePart::thinking("Rebase the branch."),
            MessagePart::thinking(" I should check the status first"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(
            stripped[0].thinking_content(),
            Some("Rebase the branch.\n\nI should check the status first")
        );
    }

    #[test]
    fn strip_plan_markup_keeps_utterance_boundaries() {
        let parts = vec![
            MessagePart::thinking("Hello, let me look at this repo."),
            MessagePart::thinking(" Alright, now I know it."),
            MessagePart::thinking(" Let me do the change."),
            MessagePart::thinking("the file needs edits"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(
            stripped[0].thinking_content(),
            Some(
                "Hello, let me look at this repo.\n\nAlright, now I know it.\n\nLet me do the change.the file needs edits"
            )
        );
    }

    #[test]
    fn strip_plan_markup_still_strips_block_split_at_sentence_boundary() {
        let parts = vec![
            MessagePart::text("All done."),
            MessagePart::text("<update_plan><step>A</step></update_plan>"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(stripped[0].text_content(), Some("All done."));
    }

    #[test]
    fn strip_plan_markup_never_mutates_text_runs() {
        // Text renders as markdown; inserting breaks could corrupt ordered
        // lists or code, so text parts merge verbatim.
        let parts = vec![
            MessagePart::text("1. First item\n2."),
            MessagePart::text(" Second item"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(
            stripped[0].text_content(),
            Some("1. First item\n2. Second item")
        );
    }

    #[test]
    fn strip_plan_markup_whitespace_parts_stay_transparent() {
        // A whitespace-only part of the other kind must not flush the open
        // buffer: the run stays whole and plan markup spanning the boundary
        // still strips.
        let parts = vec![
            MessagePart::text("a"),
            MessagePart::thinking(" "),
            MessagePart::text("b"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(stripped[0].text_content(), Some("ab"));

        let parts = vec![
            MessagePart::text("<update_plan><step>A"),
            MessagePart::thinking(" \n "),
            MessagePart::text("</step></update_plan>"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert!(stripped.is_empty());
    }

    #[test]
    fn strip_plan_markup_drops_whitespace_only_parts() {
        let parts = vec![
            MessagePart::thinking("   "),
            MessagePart::text(" \n "),
            MessagePart::thinking("real work"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        assert_eq!(stripped.len(), 1);
        assert_eq!(stripped[0].thinking_content(), Some("real work"));
        assert!(collect_text(&stripped).is_empty());
    }

    #[test]
    fn strip_plan_markup_marks_unfinished_tools_failed() {
        let tool = |id: &str, status: &str| {
            MessagePart::tool_call(ToolCallEvent {
                id: id.into(),
                title: id.into(),
                kind: "other".into(),
                status: status.into(),
                command: None,
                output: None,
                output_preview: None,
                changed_files: vec![],
                diffs: vec![],
            })
        };
        let parts = vec![
            tool("tc-1", "in_progress"),
            tool("tc-2", "pending"),
            tool("tc-3", "completed"),
        ];
        let stripped = strip_plan_markup_from_parts(parts);
        let statuses: Vec<&str> = stripped
            .iter()
            .filter_map(|p| match p {
                MessagePart::ToolCall { payload } => Some(payload.status.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(statuses, ["failed", "failed", "completed"]);
    }
}
