use std::sync::Arc;

use serde::{Deserialize, Serialize};

use super::ToolCallEvent;

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
}
