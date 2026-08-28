use agent_client_protocol::schema::v1::{ContentBlock, EmbeddedResourceResource};

pub(crate) fn text_from_content_block(block: &ContentBlock) -> Option<String> {
    match block {
        ContentBlock::Text(t) => Some(t.text.clone()),
        ContentBlock::Resource(r) => match &r.resource {
            EmbeddedResourceResource::TextResourceContents(t) => Some(t.text.clone()),
            _ => None,
        },
        _ => None,
    }
}

pub(crate) fn json_to_compact_string(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        _ => serde_json::to_string(value).unwrap_or_default(),
    }
}

pub(crate) fn truncate_preview(s: &str, max_len: usize) -> String {
    match s.char_indices().nth(max_len) {
        Some((idx, _)) => format!("{}...", &s[..idx]),
        None => s.to_string(),
    }
}

pub(crate) fn sanitize(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_preview_respects_char_boundaries() {
        assert_eq!(truncate_preview("hello world", 5), "hello...");

        let cjk = "这是一个中文字符串";
        assert_eq!(truncate_preview(cjk, 5), "这是一个中...");

        let emoji = "🌍🌎🌏🚀✨";
        assert_eq!(truncate_preview(emoji, 3), "🌍🌎🌏...");

        let mixed = "hello 世界 🌍 more";
        assert_eq!(truncate_preview(mixed, 8), "hello 世界...");
    }

    #[test]
    fn json_to_compact_string_flattens_strings() {
        assert_eq!(json_to_compact_string(&serde_json::json!("raw")), "raw");
        assert_eq!(
            json_to_compact_string(&serde_json::json!({"key": "value"})),
            "{\"key\":\"value\"}"
        );
    }

    #[test]
    fn sanitize_replaces_special_characters() {
        assert_eq!(sanitize("foo/bar.baz-qux_1.txt"), "foo_bar.baz-qux_1.txt");
        assert_eq!(sanitize("hello world!"), "hello_world_");
    }
}
