use agent_client_protocol::schema::v1::{
    SessionNotification, SessionUpdate, ToolCallContent, ToolCallLocation, ToolCallStatus,
    ToolCallUpdate, ToolKind,
};

use crate::providers::{FileDiff, MessagePart, PartEvent, ToolCallEvent};

use super::content::{json_to_compact_string, text_from_content_block, truncate_preview};

pub(crate) fn apply_notification(
    notification: &SessionNotification,
    parts: &mut Vec<MessagePart>,
) -> Option<PartEvent> {
    match &notification.update {
        SessionUpdate::AgentMessageChunk(chunk) => {
            text_from_content_block(&chunk.content).map(|text| {
                let part = MessagePart::text(text);
                parts.push(part.clone());
                PartEvent::New(part)
            })
        }
        SessionUpdate::AgentThoughtChunk(chunk) => {
            text_from_content_block(&chunk.content).map(|text| {
                let part = MessagePart::thinking(text);
                parts.push(part.clone());
                PartEvent::New(part)
            })
        }
        SessionUpdate::ToolCall(tool_call) => {
            let id = tool_call.tool_call_id.to_string();
            if let Some(idx) = parts.iter().position(|p| p.tool_id() == Some(id.as_str())) {
                let existing = match &parts[idx] {
                    MessagePart::ToolCall { payload } => payload.clone(),
                    _ => return None,
                };
                let merged = merge_tool_call_with_existing(&existing, tool_call);
                let part = MessagePart::tool_call(merged);
                parts[idx] = part.clone();
                Some(PartEvent::Update(part))
            } else {
                let ev = build_tool_call_event(tool_call);
                let part = MessagePart::tool_call(ev);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
        }
        SessionUpdate::ToolCallUpdate(update) => {
            let update_id = update.tool_call_id.to_string();
            if let Some(idx) = parts
                .iter()
                .position(|p| p.tool_id() == Some(update_id.as_str()))
            {
                let existing = match &parts[idx] {
                    MessagePart::ToolCall { payload } => payload.clone(),
                    _ => return None,
                };
                let updated = merge_tool_call_update(Some(&existing), update);
                let part = MessagePart::tool_call(updated);
                parts[idx] = part.clone();
                Some(PartEvent::Update(part))
            } else {
                let ev = merge_tool_call_update(None, update);
                let part = MessagePart::tool_call(ev);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
        }
        _ => None,
    }
}

pub(crate) fn merge_tool_call_with_existing(
    existing: &ToolCallEvent,
    tool_call: &agent_client_protocol::schema::v1::ToolCall,
) -> ToolCallEvent {
    let mut ev = build_tool_call_event(tool_call);
    if matches!(existing.status.as_str(), "completed" | "failed")
        && !matches!(ev.status.as_str(), "completed" | "failed")
    {
        ev.status = existing.status.clone();
    }
    if ev.output.is_none() {
        ev.output = existing.output.clone();
    }
    if ev.output_preview.is_none() {
        ev.output_preview = existing.output_preview.clone();
    }
    if ev.command.is_none() {
        ev.command = existing.command.clone();
    }
    if ev.changed_files.is_empty() && !existing.changed_files.is_empty() {
        ev.changed_files = existing.changed_files.clone();
    }
    ev.diffs = merge_diffs(existing.diffs.clone(), ev.diffs.clone());
    ev
}

pub(crate) fn build_tool_call_event(
    tool_call: &agent_client_protocol::schema::v1::ToolCall,
) -> ToolCallEvent {
    let id = tool_call.tool_call_id.to_string();
    let mut ev = build_tool_call_event_core(
        id,
        Some(&tool_call.title),
        Some(tool_call.kind),
        Some(tool_call.status),
        tool_call.raw_input.as_ref(),
        tool_call.raw_output.as_ref(),
        Some(&tool_call.content),
        Some(&tool_call.locations),
    );
    if !matches!(ev.status.as_str(), "completed" | "failed") {
        ev.status = status_to_string(Some(ToolCallStatus::InProgress));
    }
    ev
}

pub(crate) fn merge_tool_call_update(
    existing: Option<&ToolCallEvent>,
    update: &ToolCallUpdate,
) -> ToolCallEvent {
    let title = update
        .fields
        .title
        .as_deref()
        .or(existing.map(|e| e.title.as_str()))
        .filter(|s| !s.is_empty())
        .unwrap_or("Tool call");
    let kind = update
        .fields
        .kind
        .or(existing.map(|e| tool_kind_from_string(&e.kind)))
        .unwrap_or_default();
    let status_opt = update
        .fields
        .status
        .or(existing.and_then(|e| tool_status_from_string(&e.status)));
    let mut status = status_to_string(status_opt);
    if !matches!(status.as_str(), "completed" | "failed") && update.fields.status.is_some() {
        status = status_to_string(Some(ToolCallStatus::InProgress));
    }

    let command = update
        .fields
        .raw_input
        .as_ref()
        .map(json_to_compact_string)
        .or(existing.and_then(|e| e.command.clone()))
        .filter(|s| !s.is_empty());

    let mut output = None;
    let mut changed_files = existing
        .map(|e| e.changed_files.clone())
        .unwrap_or_default();
    let mut diffs = existing.map(|e| e.diffs.clone()).unwrap_or_default();

    if let Some(content) = update.fields.content.as_deref() {
        let (text, changed, new_diffs) = tool_call_output_from_content(content);
        output = text;
        changed_files = changed;
        diffs = merge_diffs(diffs, new_diffs);
    }

    if let Some(raw_output) = update.fields.raw_output.as_ref() {
        let text = json_to_compact_string(raw_output);
        if !text.is_empty() {
            output = Some(text);
        }
    }

    if output.is_none() {
        output = existing
            .and_then(|e| e.output.clone())
            .filter(|s| !s.is_empty());
    }

    if let Some(locations) = update.fields.locations.as_deref() {
        changed_files = locations
            .iter()
            .map(|l| l.path.to_string_lossy().into_owned())
            .collect();
    }

    let output_preview = output.as_deref().map(|o| truncate_preview(o, 120));

    ToolCallEvent {
        id: update.tool_call_id.to_string(),
        title: title.to_string(),
        kind: kind_to_string(Some(kind)),
        status,
        command,
        output,
        output_preview,
        changed_files,
        diffs,
    }
}

pub(crate) fn build_tool_call_event_core(
    id: impl AsRef<str>,
    title: Option<&str>,
    kind: Option<ToolKind>,
    status: Option<ToolCallStatus>,
    raw_input: Option<&serde_json::Value>,
    raw_output: Option<&serde_json::Value>,
    content: Option<&[ToolCallContent]>,
    locations: Option<&[ToolCallLocation]>,
) -> ToolCallEvent {
    let title = title.filter(|s| !s.is_empty()).unwrap_or("Tool call");
    let status = status_to_string(status);
    let command = raw_input.map(json_to_compact_string);

    let (mut output, mut changed_files, diffs) = content
        .map(tool_call_output_from_content)
        .unwrap_or((None, Vec::new(), Vec::new()));

    if let Some(raw_output) = raw_output {
        let text = json_to_compact_string(raw_output);
        if !text.is_empty() {
            output = Some(text);
        }
    }

    if let Some(locations) = locations {
        for l in locations {
            changed_files.push(l.path.to_string_lossy().into_owned());
        }
    }

    let output_preview = output.as_deref().map(|o| truncate_preview(o, 120));

    ToolCallEvent {
        id: id.as_ref().to_string(),
        title: title.to_string(),
        kind: kind_to_string(kind),
        status,
        command,
        output,
        output_preview,
        changed_files,
        diffs,
    }
}

pub(crate) fn merge_diffs(existing: Vec<FileDiff>, new: Vec<FileDiff>) -> Vec<FileDiff> {
    let mut merged: Vec<FileDiff> = existing;
    for diff in new {
        if let Some(slot) = merged.iter_mut().find(|d| d.path == diff.path) {
            *slot = diff;
        } else {
            merged.push(diff);
        }
    }
    merged
}

pub(crate) fn tool_call_output_from_content(
    content: &[ToolCallContent],
) -> (Option<String>, Vec<String>, Vec<FileDiff>) {
    let mut output_parts = Vec::new();
    let mut changed = Vec::new();
    let mut diffs = Vec::new();
    for c in content {
        match c {
            ToolCallContent::Content(content) => {
                if let Some(text) = text_from_content_block(&content.content) {
                    output_parts.push(text);
                }
            }
            ToolCallContent::Diff(diff) => {
                let path = diff.path.to_string_lossy().into_owned();
                changed.push(path.clone());
                diffs.push(FileDiff {
                    path,
                    old_text: diff.old_text.clone(),
                    new_text: diff.new_text.clone(),
                });
            }
            _ => {}
        }
    }
    let output = if output_parts.is_empty() {
        None
    } else {
        Some(output_parts.join(""))
    };
    (output, changed, diffs)
}

pub(crate) fn tool_kind_from_string(s: &str) -> ToolKind {
    match s {
        "read" => ToolKind::Read,
        "edit" => ToolKind::Edit,
        "delete" => ToolKind::Delete,
        "move" => ToolKind::Move,
        "search" => ToolKind::Search,
        "execute" => ToolKind::Execute,
        "think" => ToolKind::Think,
        "fetch" => ToolKind::Fetch,
        "switch_mode" => ToolKind::SwitchMode,
        _ => ToolKind::Other,
    }
}

pub(crate) fn tool_status_from_string(s: &str) -> Option<ToolCallStatus> {
    match s {
        "pending" => Some(ToolCallStatus::Pending),
        "in_progress" => Some(ToolCallStatus::InProgress),
        "completed" => Some(ToolCallStatus::Completed),
        "failed" => Some(ToolCallStatus::Failed),
        _ => None,
    }
}

fn kind_to_string(kind: Option<ToolKind>) -> String {
    match kind {
        Some(ToolKind::Read) => "read".to_string(),
        Some(ToolKind::Edit) => "edit".to_string(),
        Some(ToolKind::Delete) => "delete".to_string(),
        Some(ToolKind::Move) => "move".to_string(),
        Some(ToolKind::Search) => "search".to_string(),
        Some(ToolKind::Execute) => "execute".to_string(),
        Some(ToolKind::Think) => "think".to_string(),
        Some(ToolKind::Fetch) => "fetch".to_string(),
        Some(ToolKind::SwitchMode) => "switch_mode".to_string(),
        Some(ToolKind::Other) | None => "other".to_string(),
        Some(_) => "other".to_string(),
    }
}

fn status_to_string(status: Option<ToolCallStatus>) -> String {
    match status {
        Some(ToolCallStatus::Pending) => "pending".to_string(),
        Some(ToolCallStatus::InProgress) => "in_progress".to_string(),
        Some(ToolCallStatus::Completed) => "completed".to_string(),
        Some(ToolCallStatus::Failed) => "failed".to_string(),
        Some(_) => "in_progress".to_string(),
        None => "in_progress".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{collect_text, collect_thinking};
    use agent_client_protocol::schema::v1::{
        ContentBlock, ContentChunk, Diff, TextContent, ToolCallUpdateFields,
    };

    fn note(text: &str) -> SessionNotification {
        SessionNotification::new(
            "session",
            SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))),
        )
    }

    fn thought(text: &str) -> SessionNotification {
        SessionNotification::new(
            "session",
            SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))),
        )
    }

    fn tool_call(id: &str, title: &str) -> SessionNotification {
        SessionNotification::new(
            "session",
            SessionUpdate::ToolCall(
                agent_client_protocol::schema::v1::ToolCall::new(id.to_string(), title.to_string())
                    .kind(ToolKind::Read),
            ),
        )
    }

    fn tool_update(id: &str, status: ToolCallStatus, output: &str) -> SessionNotification {
        SessionNotification::new(
            "session",
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                id.to_string(),
                ToolCallUpdateFields::new()
                    .status(status)
                    .raw_output(serde_json::Value::String(output.into())),
            )),
        )
    }

    #[test]
    fn parts_keep_text_thinking_tool_order() {
        let mut parts = Vec::new();
        apply_notification(&note("hello "), &mut parts);
        apply_notification(&thought("hmm"), &mut parts);
        apply_notification(&note("world"), &mut parts);
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);

        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], MessagePart::text("hello "));
        assert_eq!(parts[1], MessagePart::thinking("hmm"));
        assert_eq!(parts[2], MessagePart::text("world"));
        assert!(matches!(&parts[3], MessagePart::ToolCall { payload } if payload.id == "tc-1"));
        assert_eq!(collect_text(&parts), "hello world");
        assert_eq!(collect_thinking(&parts), "hmm");
    }

    #[test]
    fn tool_call_update_before_initial_call_does_not_duplicate() {
        let mut parts = Vec::new();
        apply_notification(
            &tool_update("tc-1", ToolCallStatus::Completed, "ok"),
            &mut parts,
        );
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);

        assert_eq!(parts.len(), 1);
        assert!(
            matches!(&parts[0], MessagePart::ToolCall { payload } if payload.id == "tc-1" && payload.title == "Read main.rs" && payload.output.as_deref() == Some("ok")),
            "update before the initial call should still resolve to a single part"
        );
    }

    #[test]
    fn tool_call_update_maps_to_same_index() {
        let mut parts = Vec::new();
        apply_notification(&tool_call("tc-1", "Read main.rs"), &mut parts);
        apply_notification(&note("found it"), &mut parts);
        apply_notification(
            &tool_update("tc-1", ToolCallStatus::Completed, "ok"),
            &mut parts,
        );

        assert_eq!(parts.len(), 2);
        let first = &parts[0];
        assert!(
            matches!(first, MessagePart::ToolCall { payload } if payload.id == "tc-1" && payload.status == "completed" && payload.output.as_deref() == Some("ok")),
            "tool call update should replace the original part in place"
        );
        assert_eq!(parts[1], MessagePart::text("found it"));
    }

    #[test]
    fn tool_call_output_from_content_handles_chinese() {
        let text = "中文工具输出";
        let content = vec![ToolCallContent::from(ContentBlock::Text(TextContent::new(
            text,
        )))];
        let (output, changed, diffs) = tool_call_output_from_content(&content);
        assert_eq!(output.as_deref(), Some(text));
        assert!(changed.is_empty());
        assert!(diffs.is_empty());
    }

    #[test]
    fn tool_call_output_from_content_extracts_diffs() {
        let content = vec![
            ToolCallContent::from(ContentBlock::Text(TextContent::new("editing"))),
            ToolCallContent::Diff(
                Diff::new("/tmp/src/main.rs", "fn main() {}\n")
                    .old_text("fn main() {\n    todo!()\n}\n"),
            ),
            ToolCallContent::Diff(Diff::new("/tmp/src/new.rs", "pub fn x() {}\n")),
        ];
        let (output, changed, diffs) = tool_call_output_from_content(&content);
        assert_eq!(output.as_deref(), Some("editing"));
        assert_eq!(changed, vec!["/tmp/src/main.rs", "/tmp/src/new.rs"]);
        assert_eq!(diffs.len(), 2);
        assert_eq!(diffs[0].path, "/tmp/src/main.rs");
        assert_eq!(
            diffs[0].old_text.as_deref(),
            Some("fn main() {\n    todo!()\n}\n")
        );
        assert_eq!(diffs[0].new_text, "fn main() {}\n");
        assert_eq!(diffs[1].path, "/tmp/src/new.rs");
        assert!(diffs[1].old_text.is_none());
        assert_eq!(diffs[1].new_text, "pub fn x() {}\n");
    }

    #[test]
    fn merge_diffs_replaces_existing_path_in_place() {
        let existing = vec![
            FileDiff {
                path: "/a.rs".into(),
                old_text: Some("old a".into()),
                new_text: "new a v1".into(),
            },
            FileDiff {
                path: "/b.rs".into(),
                old_text: None,
                new_text: "new b".into(),
            },
        ];
        let new = vec![FileDiff {
            path: "/a.rs".into(),
            old_text: Some("old a".into()),
            new_text: "new a v2".into(),
        }];
        let merged = merge_diffs(existing, new);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].path, "/a.rs");
        assert_eq!(merged[0].new_text, "new a v2");
        assert_eq!(merged[1].path, "/b.rs");
    }

    #[test]
    fn merge_diffs_appends_new_paths() {
        let existing = vec![FileDiff {
            path: "/a.rs".into(),
            old_text: None,
            new_text: "a".into(),
        }];
        let new = vec![FileDiff {
            path: "/b.rs".into(),
            old_text: None,
            new_text: "b".into(),
        }];
        let merged = merge_diffs(existing, new);
        assert_eq!(
            merged.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(),
            vec!["/a.rs", "/b.rs"],
        );
    }

    #[test]
    fn merge_tool_call_update_preserves_and_replaces_diffs() {
        let first = ToolCallUpdate::new(
            "tc-1",
            ToolCallUpdateFields::new().content(vec![ToolCallContent::Diff(
                Diff::new("/a.rs", "v1").old_text("old"),
            )]),
        );
        let event = merge_tool_call_update(None, &first);
        assert_eq!(event.diffs.len(), 1);
        assert_eq!(event.diffs[0].new_text, "v1");

        let second = ToolCallUpdate::new(
            "tc-1",
            ToolCallUpdateFields::new().content(vec![ToolCallContent::Diff(
                Diff::new("/a.rs", "v2").old_text("old"),
            )]),
        );
        let event = merge_tool_call_update(Some(&event), &second);
        assert_eq!(event.diffs.len(), 1);
        assert_eq!(event.diffs[0].new_text, "v2");
    }

    #[test]
    fn merge_tool_call_update_truncates_chinese_preview() {
        let long = "这是一个测试".repeat(25);
        let content = vec![ToolCallContent::from(ContentBlock::Text(TextContent::new(
            &long,
        )))];
        let update = ToolCallUpdate::new(
            "tc-1",
            ToolCallUpdateFields::new()
                .status(ToolCallStatus::Completed)
                .content(content),
        );

        let event = merge_tool_call_update(None, &update);
        assert_eq!(event.output.as_deref(), Some(long.as_str()));

        let preview = event.output_preview.expect("preview should be set");
        assert_eq!(preview, "这是一个测试".repeat(20) + "...");
        assert_eq!(preview.chars().count(), 123);
    }
}
