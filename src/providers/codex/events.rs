//! Translate Codex app-server notifications into message parts.
//!
//! Codex streams text as `item/agentMessage/delta` and reasoning as
//! `item/reasoning/*Delta`, and reports tool-ish work as `item/started` /
//! `item/completed` carrying a typed [`Item`]. Each streamed item gets one
//! part that is updated in place, so the SSE consumer sees ordered
//! `New`/`Update` events just like with the ACP providers.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use crate::providers::acp::content::truncate_preview;
use crate::providers::{MessagePart, PartEvent, ToolCallEvent, UsageSnapshot};

use super::wire::{Item, TokenUsage};

/// Per-turn accumulator: maps codex item ids to the part they own.
#[derive(Default)]
pub struct TurnTranslator {
    tool_items: HashMap<String, usize>,
    /// Item ids whose content already arrived through deltas; the completed
    /// item is then not re-emitted.
    streamed: HashSet<String>,
    /// Buffered `*/outputDelta` text for tool items that have not reported a
    /// final `aggregatedOutput` yet.
    output_buffers: HashMap<String, String>,
    /// Latest cumulative session token usage.
    pub usage: Option<UsageSnapshot>,
}

impl TurnTranslator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed one server notification. Returns a part event to forward, if the
    /// notification produced or updated a part.
    pub fn apply(
        &mut self,
        method: &str,
        params: &Value,
        parts: &mut Vec<MessagePart>,
    ) -> Option<PartEvent> {
        match method {
            "item/agentMessage/delta" | "item/plan/delta" => {
                let (item_id, delta) = (str_field(params, "itemId")?, str_field(params, "delta")?);
                self.streamed.insert(item_id);
                let part = MessagePart::text(delta);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
            "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => {
                let (item_id, delta) = (str_field(params, "itemId")?, str_field(params, "delta")?);
                self.streamed.insert(item_id);
                let part = MessagePart::thinking(delta);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
            "item/commandExecution/outputDelta" | "item/fileChange/outputDelta" => {
                let (item_id, delta) = (str_field(params, "itemId")?, str_field(params, "delta")?);
                self.output_buffers
                    .entry(item_id.clone())
                    .or_default()
                    .push_str(&delta);
                let idx = *self.tool_items.get(&item_id)?;
                Some(self.refresh_tool_output(parts, idx, &item_id))
            }
            "item/started" | "item/completed" => {
                let item: Item = serde_json::from_value(params.get("item")?.clone()).ok()?;
                self.apply_item(item, parts, method == "item/completed")
            }
            "thread/tokenUsage/updated" => {
                let usage: TokenUsage =
                    serde_json::from_value(params.get("tokenUsage")?.clone()).ok()?;
                self.usage = Some(UsageSnapshot {
                    input_tokens: usage.total.input_tokens,
                    output_tokens: usage.total.output_tokens,
                    thought_tokens: usage.total.reasoning_output_tokens,
                    cached_read_tokens: usage.total.cached_input_tokens,
                    cached_write_tokens: usage.total.cache_write_input_tokens,
                    total_tokens: usage.total.total_tokens,
                    cost_amount: None,
                    cost_currency: None,
                });
                None
            }
            _ => None,
        }
    }

    /// Re-emit a tool part after its buffered output changed.
    fn refresh_tool_output(
        &mut self,
        parts: &mut [MessagePart],
        idx: usize,
        item_id: &str,
    ) -> PartEvent {
        if let MessagePart::ToolCall { payload } = &parts[idx] {
            let mut ev = payload.clone();
            ev.output = self.output_buffers.get(item_id).cloned();
            ev.output_preview = ev.output.as_deref().map(|o| truncate_preview(o, 120));
            let part = MessagePart::tool_call(ev);
            parts[idx] = part.clone();
            return PartEvent::Update(part);
        }
        PartEvent::Update(parts[idx].clone())
    }

    /// Create or update the part for a completed/started item.
    fn apply_item(
        &mut self,
        item: Item,
        parts: &mut Vec<MessagePart>,
        completed: bool,
    ) -> Option<PartEvent> {
        match item.kind.as_str() {
            "agentMessage" | "plan" if completed => {
                if self.streamed.contains(&item.id) {
                    return None;
                }
                self.streamed.insert(item.id.clone());
                let text = item.fields.get("text")?.as_str()?;
                if text.is_empty() {
                    return None;
                }
                let part = MessagePart::text(text);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
            "reasoning" if completed => {
                if self.streamed.contains(&item.id) {
                    return None;
                }
                self.streamed.insert(item.id.clone());
                let text = string_list(&item.fields, "summary")
                    .into_iter()
                    .chain(string_list(&item.fields, "content"))
                    .collect::<Vec<_>>()
                    .join("\n");
                if text.is_empty() {
                    return None;
                }
                let part = MessagePart::thinking(text);
                parts.push(part.clone());
                Some(PartEvent::New(part))
            }
            "commandExecution" => Some(self.upsert_tool(parts, command_event(&item))),
            "fileChange" => Some(self.upsert_tool(parts, file_change_event(&item))),
            "mcpToolCall" | "dynamicToolCall" | "collabAgentToolCall" => {
                Some(self.upsert_tool(parts, tool_event(&item)))
            }
            "webSearch" if completed => {
                let query = item
                    .fields
                    .get("query")
                    .and_then(Value::as_str)
                    .unwrap_or("web search");
                Some(self.upsert_tool(
                    parts,
                    ToolCallEvent {
                        id: item.id.clone(),
                        title: format!("Search: {query}"),
                        kind: "search".into(),
                        status: "completed".into(),
                        command: Some(query.to_string()),
                        output: None,
                        output_preview: None,
                        changed_files: vec![],
                        diffs: vec![],
                    },
                ))
            }
            _ => None,
        }
    }

    fn upsert_tool(&mut self, parts: &mut Vec<MessagePart>, ev: ToolCallEvent) -> PartEvent {
        // Merge any buffered output deltas that arrived before the item did.
        if ev.output.is_none() {
            if let Some(buf) = self.output_buffers.get(&ev.id) {
                let mut ev = ev;
                ev.output = Some(buf.clone());
                ev.output_preview = ev.output.as_deref().map(|o| truncate_preview(o, 120));
                return self.upsert_tool(parts, ev);
            }
        }
        if let Some(&idx) = self.tool_items.get(&ev.id) {
            if let MessagePart::ToolCall { payload } = &parts[idx] {
                let mut merged = payload.clone();
                if !matches!(merged.status.as_str(), "completed" | "failed") {
                    merged.status = ev.status;
                }
                if ev.title != "Tool call" {
                    merged.title = ev.title;
                }
                merged.command = ev.command.or(merged.command);
                merged.output = ev.output.or(merged.output);
                merged.output_preview = merged.output.as_deref().map(|o| truncate_preview(o, 120));
                if !ev.changed_files.is_empty() {
                    merged.changed_files = ev.changed_files;
                }
                if !ev.diffs.is_empty() {
                    merged.diffs = ev.diffs;
                }
                let part = MessagePart::tool_call(merged);
                parts[idx] = part.clone();
                return PartEvent::Update(part);
            }
        }
        let part = MessagePart::tool_call(ev.clone());
        self.tool_items.insert(ev.id, parts.len());
        parts.push(part.clone());
        PartEvent::New(part)
    }
}

fn command_event(item: &Item) -> ToolCallEvent {
    let command = item
        .fields
        .get("command")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let output = output_from(item);
    ToolCallEvent {
        id: item.id.clone(),
        title: if command.is_empty() {
            "Command".to_string()
        } else {
            truncate_preview(&command, 80)
        },
        kind: "execute".into(),
        status: map_status(item.fields.get("status")),
        command: (!command.is_empty()).then_some(command),
        output: output.clone(),
        output_preview: output.as_deref().map(|o| truncate_preview(o, 120)),
        changed_files: vec![],
        diffs: vec![],
    }
}

fn file_change_event(item: &Item) -> ToolCallEvent {
    let changes = item
        .fields
        .get("changes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut files = Vec::new();
    let mut diffs = Vec::new();
    for change in &changes {
        if let Some(path) = change.get("path").and_then(Value::as_str) {
            files.push(path.to_string());
        }
        if let Some(diff) = change.get("diff").and_then(Value::as_str) {
            diffs.push(diff.to_string());
        }
    }
    let output = (!diffs.is_empty()).then(|| diffs.join("\n"));
    ToolCallEvent {
        id: item.id.clone(),
        title: if files.len() == 1 {
            format!("Edit {}", files[0])
        } else {
            format!("Edit {} files", files.len())
        },
        kind: "edit".into(),
        status: map_status(item.fields.get("status")),
        command: None,
        output: output.clone(),
        output_preview: output.as_deref().map(|o| truncate_preview(o, 120)),
        changed_files: files,
        diffs: vec![],
    }
}

fn tool_event(item: &Item) -> ToolCallEvent {
    let server = item.fields.get("server").and_then(Value::as_str);
    let tool = item
        .fields
        .get("tool")
        .and_then(Value::as_str)
        .unwrap_or("tool call");
    let title = match server {
        Some(s) => format!("{s} · {tool}"),
        None => tool.to_string(),
    };
    let output = item
        .fields
        .get("result")
        .or_else(|| item.fields.get("error"))
        .or_else(|| item.fields.get("arguments"))
        .map(compact_json);
    ToolCallEvent {
        id: item.id.clone(),
        title,
        kind: "other".into(),
        status: map_status(item.fields.get("status")),
        command: item
            .fields
            .get("arguments")
            .map(compact_json)
            .filter(|s| !s.is_empty()),
        output: output.clone(),
        output_preview: output.as_deref().map(|o| truncate_preview(o, 120)),
        changed_files: vec![],
        diffs: vec![],
    }
}

fn map_status(status: Option<&Value>) -> String {
    match status.and_then(Value::as_str) {
        Some("completed") => "completed",
        Some("failed" | "declined") => "failed",
        _ => "in_progress",
    }
    .to_string()
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().map(str::to_string)
}

fn string_list(fields: &serde_json::Map<String, Value>, key: &str) -> Vec<String> {
    fields
        .get(key)
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn output_from(item: &Item) -> Option<String> {
    item.fields
        .get("aggregatedOutput")
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn compact_json(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn message_deltas_stream_as_new_parts() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        for delta in ["Hel", "lo"] {
            let ev = t
                .apply(
                    "item/agentMessage/delta",
                    &json!({"threadId":"th","turnId":"tu","itemId":"m1","delta":delta}),
                    &mut parts,
                )
                .unwrap();
            assert!(matches!(ev, PartEvent::New(_)));
        }
        // One part per delta; the joined text still reads "Hello".
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].text_content(), Some("Hel"));
        assert_eq!(
            parts
                .iter()
                .filter_map(|p| p.text_content())
                .collect::<String>(),
            "Hello"
        );
    }

    #[test]
    fn reasoning_deltas_become_thinking() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        let ev = t.apply(
            "item/reasoning/textDelta",
            &json!({"itemId":"r1","delta":"hmm"}),
            &mut parts,
        );
        assert!(matches!(ev, Some(PartEvent::New(_))));
        t.apply(
            "item/reasoning/summaryTextDelta",
            &json!({"itemId":"r1","delta":"!"}),
            &mut parts,
        );
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].thinking_content(), Some("hmm"));
        assert_eq!(parts[1].thinking_content(), Some("!"));
    }

    #[test]
    fn completed_agent_message_not_duplicated_after_deltas() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        t.apply(
            "item/agentMessage/delta",
            &json!({"itemId":"m1","delta":"hi"}),
            &mut parts,
        );
        t.apply(
            "item/completed",
            &json!({"item":{"id":"m1","type":"agentMessage","text":"hi"}}),
            &mut parts,
        );
        assert_eq!(parts.len(), 1);
    }

    #[test]
    fn completed_command_becomes_tool_call() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        t.apply(
            "item/completed",
            &json!({"item":{
                "id":"c1","type":"commandExecution","command":"ls -la",
                "status":"completed","exitCode":0,"aggregatedOutput":"total 4"
            }}),
            &mut parts,
        );
        let MessagePart::ToolCall { payload } = &parts[0] else {
            panic!("expected tool call")
        };
        assert_eq!(payload.kind, "execute");
        assert_eq!(payload.status, "completed");
        assert_eq!(payload.command.as_deref(), Some("ls -la"));
        assert_eq!(payload.output.as_deref(), Some("total 4"));
    }

    #[test]
    fn output_delta_updates_tool_output() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        t.apply(
            "item/started",
            &json!({"item":{"id":"c1","type":"commandExecution","command":"ls","status":"inProgress"}}),
            &mut parts,
        );
        t.apply(
            "item/commandExecution/outputDelta",
            &json!({"itemId":"c1","delta":"file.txt\n"}),
            &mut parts,
        );
        let MessagePart::ToolCall { payload } = &parts[0] else {
            panic!("expected tool call")
        };
        assert_eq!(payload.output.as_deref(), Some("file.txt\n"));
        assert_eq!(payload.status, "in_progress");
    }

    #[test]
    fn file_change_collects_paths_and_diffs() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        t.apply(
            "item/completed",
            &json!({"item":{"id":"f1","type":"fileChange","status":"completed","changes":[
                {"path":"a.rs","kind":{"type":"update"},"diff":"@@ -1 +1 @@"},
                {"path":"b.rs","kind":{"type":"add"},"diff":"+new"}
            ]}}),
            &mut parts,
        );
        let MessagePart::ToolCall { payload } = &parts[0] else {
            panic!("expected tool call")
        };
        assert_eq!(payload.kind, "edit");
        assert_eq!(payload.changed_files, vec!["a.rs", "b.rs"]);
        assert!(payload.output.as_deref().unwrap().contains("@@ -1 +1 @@"));
    }

    #[test]
    fn token_usage_updates_snapshot() {
        let mut t = TurnTranslator::new();
        let mut parts = vec![];
        t.apply(
            "thread/tokenUsage/updated",
            &json!({"tokenUsage":{"total":{
                "inputTokens":10,"outputTokens":5,"reasoningOutputTokens":2,
                "cachedInputTokens":3,"cacheWriteInputTokens":0,"totalTokens":15
            }}}),
            &mut parts,
        );
        let u = t.usage.unwrap();
        assert_eq!(u.total_tokens, 15);
        assert_eq!(u.thought_tokens, 2);
    }
}
