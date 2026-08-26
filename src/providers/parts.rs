use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::ToolCallEvent;
use crate::plan;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessagePart {
    Text { content: String },
    Thinking { content: String },
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
pub fn strip_plan_markup_from_parts(parts: Vec<MessagePart>) -> Vec<MessagePart> {
    let mut out = Vec::with_capacity(parts.len());
    let mut text_buf = String::new();
    let mut thinking_buf = String::new();

    for part in parts {
        match part {
            MessagePart::Text { content } => {
                flush_thinking(&mut thinking_buf, &mut out);
                text_buf.push_str(&content);
            }
            MessagePart::Thinking { content } => {
                flush_text(&mut text_buf, &mut out);
                thinking_buf.push_str(&content);
            }
            MessagePart::ToolCall { .. } => {
                flush_text(&mut text_buf, &mut out);
                flush_thinking(&mut thinking_buf, &mut out);
                out.push(part);
            }
        }
    }
    flush_text(&mut text_buf, &mut out);
    flush_thinking(&mut thinking_buf, &mut out);
    out
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
    use super::*;
    use super::super::ToolCallEvent;

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
        let text = MessagePart::text(
            r#"<update_plan explanation="Build"><step>A</step></update_plan>"#,
        )
        .strip_plan_markup();
        assert_eq!(text.text_content(), Some(""));

        let thinking = MessagePart::thinking(
            "Plan: <proposed_plan><step>X</step></proposed_plan> done",
        )
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
}
