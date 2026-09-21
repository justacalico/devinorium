//! Token estimation for context-budget accounting.
//!
//! Devinorium does not ship a real tokenizer; counting is heuristic. ASCII
//! text averages about four characters per token, while non-ASCII text (CJK,
//! emoji, most accented scripts) is closer to one token per character, so the
//! estimate splits on `is_ascii`. Images are estimated from their pixel
//! dimensions when the header can be parsed and from byte size otherwise.
//! Everything here errs slightly high: the numbers feed warnings and the
//! pre-send limit check, where an overestimate is safer than letting the
//! provider hit a hard context error mid-turn.

use super::Attachment;

/// Fixed overhead charged per message for role wrappers and separators.
pub const MESSAGE_OVERHEAD_TOKENS: u64 = 8;

/// Token estimate for a stored path reference: the prompt block lists one
/// line per path plus a short header.
const PATH_REF_TOKENS: u64 = 40;

/// Token estimate for a stored thread reference: transcripts share a 4000
/// character budget, which is about 1000 tokens worst case.
const THREAD_REF_TOKENS: u64 = 1100;

/// Token estimate for a stored machine reference: the control-instruction
/// block is a fixed ~700 characters.
const MACHINE_REF_TOKENS: u64 = 350;

/// Token estimate for a stored binary attachment. Providers send a path
/// reference, not the bytes, so the cost is just the marker line.
const BINARY_ATTACHMENT_TOKENS: u64 = 40;

/// Fallback estimate for a stored image whose dimensions are unknown.
const STORED_IMAGE_TOKENS: u64 = 1500;

/// Rough token estimate for a text string.
///
/// ASCII runs count four characters per token; every other character counts
/// one. The result is deliberately approximate — it exists to compare a
/// prompt against a context limit, not to bill anyone.
pub fn estimate_tokens(text: &str) -> u64 {
    let mut ascii = 0u64;
    let mut other = 0u64;
    for c in text.chars() {
        if c.is_ascii() {
            ascii += 1;
        } else {
            other += 1;
        }
    }
    ascii.div_ceil(4) + other
}

/// True when the attachment's bytes are likely to be rendered as text by the
/// agent (either inline or by reading the staged file once).
fn is_text_like(mime: &str, filename: &str) -> bool {
    let mime = mime.to_ascii_lowercase();
    if mime.starts_with("text/") || mime == "image/svg+xml" {
        return true;
    }
    matches!(
        mime.as_str(),
        "application/json"
            | "application/xml"
            | "application/javascript"
            | "application/x-javascript"
            | "application/yaml"
            | "application/x-yaml"
            | "application/toml"
            | "application/x-sh"
            | "application/x-httpd-php"
            | "application/typescript"
    ) || mime.ends_with("+json")
        || mime.ends_with("+xml")
        || matches!(
            filename.rsplit('.').next(),
            Some(ext) if matches!(
                ext.to_ascii_lowercase().as_str(),
                "txt" | "md" | "markdown" | "rs" | "py" | "js" | "ts" | "tsx"
                    | "jsx" | "json" | "jsonl" | "yaml" | "yml" | "toml"
                    | "xml" | "html" | "htm" | "css" | "scss" | "sh" | "bash"
                    | "zsh" | "fish" | "c" | "h" | "cc" | "cpp" | "hpp"
                    | "java" | "kt" | "kts" | "go" | "rb" | "php" | "swift"
                    | "cs" | "dart" | "lua" | "r" | "sql" | "csv" | "tsv"
                    | "ini" | "cfg" | "conf" | "env" | "log" | "svg"
            )
        )
}

/// (width, height) parsed out of a PNG, GIF, or JPEG header.
fn image_dimensions(data: &[u8]) -> Option<(u64, u64)> {
    // PNG: 8-byte signature, then IHDR length/type, width/height BE u32.
    if data.len() >= 24 && data.starts_with(b"\x89PNG\r\n\x1a\n") {
        let w = u32::from_be_bytes(data[16..20].try_into().ok()?) as u64;
        let h = u32::from_be_bytes(data[20..24].try_into().ok()?) as u64;
        return (w > 0 && h > 0).then_some((w, h));
    }
    // GIF: "GIF8x[89]a", width/height LE u16.
    if data.len() >= 10 && (data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a")) {
        let w = u16::from_le_bytes(data[6..8].try_into().ok()?) as u64;
        let h = u16::from_le_bytes(data[8..10].try_into().ok()?) as u64;
        return (w > 0 && h > 0).then_some((w, h));
    }
    // JPEG: walk markers until a start-of-frame segment holds the size.
    if data.len() >= 4 && data[0] == 0xFF && data[1] == 0xD8 {
        let mut i = 2usize;
        while i + 9 < data.len() {
            if data[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = data[i + 1];
            // SOF markers carry dimensions; skip standalone/reset markers.
            if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
                let h = u16::from_be_bytes(data[i + 5..i + 7].try_into().ok()?) as u64;
                let w = u16::from_be_bytes(data[i + 7..i + 9].try_into().ok()?) as u64;
                return (w > 0 && h > 0).then_some((w, h));
            }
            let len = u16::from_be_bytes(data[i + 2..i + 4].try_into().ok()?) as usize;
            i += 2 + len.max(1);
        }
    }
    None
}

/// Estimated vision tokens for a raster image. Providers scale differently,
/// but roughly 750 pixels per token matches the published formulas for the
/// major APIs; clamped so tiny icons and giant rasters stay sane.
fn image_tokens(data: &[u8]) -> u64 {
    let estimated = match image_dimensions(data) {
        Some((w, h)) => (w * h) / 750,
        None => (data.len() as u64) / 750,
    };
    estimated.clamp(85, 16_000)
}

/// Estimated tokens for one uploaded attachment in a pending send.
///
/// Raster images are inlined by providers and priced by resolution, so they
/// use the dimension/byte estimate. Text-like files count their contents —
/// providers stage them on disk but the agent will read them into context.
/// Other binaries only ever appear as a path reference, so their cost is the
/// marker line the provider emits, not the file size.
pub fn estimate_attachment_tokens(att: &Attachment) -> u64 {
    // The provider-written marker line ("[Attachment: name (N bytes)]") or
    // the image block wrapper.
    let wrapper = estimate_tokens(&format!("[Attachment: {}]", att.filename)) + 4;
    let mime = att.mime.to_ascii_lowercase();
    if mime.starts_with("image/") && mime != "image/svg+xml" {
        return wrapper + image_tokens(&att.data);
    }
    if is_text_like(&mime, &att.filename) {
        if let Ok(text) = std::str::from_utf8(&att.data) {
            return wrapper + estimate_tokens(text);
        }
        return wrapper + (att.data.len() as u64) / 64;
    }
    wrapper + BINARY_ATTACHMENT_TOKENS
}

/// Estimated tokens for one entry in a stored message's `attachments` JSON.
///
/// Blob bytes are not loaded here — only the metadata (filename, mime, size)
/// is available — so the estimate leans on `size` for text and a flat figure
/// for images. Path, thread, and machine entries use the size of the prompt
/// block they originally produced.
pub fn estimate_attachment_meta_tokens(meta: &serde_json::Value) -> u64 {
    match meta.get("kind").and_then(|k| k.as_str()) {
        Some("path") => return PATH_REF_TOKENS,
        Some("thread") => return THREAD_REF_TOKENS,
        Some("machine") => return MACHINE_REF_TOKENS,
        _ => {}
    }
    let mime = meta
        .get("mime")
        .and_then(|m| m.as_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let filename = meta
        .get("filename")
        .and_then(|f| f.as_str())
        .unwrap_or_default();
    let size = meta.get("size").and_then(|s| s.as_u64()).unwrap_or(0);
    if mime.starts_with("image/") && mime != "image/svg+xml" {
        // Dimensions are not stored, so scale by byte size like the
        // pending-send fallback; a big photo must not shrink to the small
        // flat rate once it lands in history.
        return (size / 750).clamp(STORED_IMAGE_TOKENS, 16_000);
    }
    if is_text_like(&mime, filename) {
        // Roughly four characters per token for stored text.
        return (size / 4).clamp(1, 250_000) + BINARY_ATTACHMENT_TOKENS;
    }
    BINARY_ATTACHMENT_TOKENS
}

/// Estimated tokens for one persisted message row.
///
/// `content_length` and `parts_length` come from generated columns so they
/// report the true stored size even when the row was truncated for the API.
/// `parts` (when present) already serializes text + thinking + tool calls, so
/// it is the superset for assistant rows; taking the max avoids
/// double-counting the text columns against it.
pub fn estimate_message_tokens(
    content_length: u64,
    thinking_len: u64,
    parts_length: u64,
    attachments_json: &str,
) -> u64 {
    let text_chars = content_length + thinking_len;
    let body = text_chars.max(parts_length).div_ceil(4);
    let mut attachments = 0u64;
    if let Ok(list) = serde_json::from_str::<Vec<serde_json::Value>>(attachments_json) {
        for item in &list {
            attachments += estimate_attachment_meta_tokens(item);
        }
    }
    body + attachments + MESSAGE_OVERHEAD_TOKENS
}

/// Estimated tokens for a pending send: the composed prompt plus attachments.
pub fn estimate_send_tokens(prompt: &str, attachments: &[Attachment]) -> u64 {
    estimate_tokens(prompt)
        + attachments.iter().map(estimate_attachment_tokens).sum::<u64>()
        + MESSAGE_OVERHEAD_TOKENS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn att(filename: &str, mime: &str, data: &[u8]) -> Attachment {
        Attachment {
            filename: filename.into(),
            mime: mime.into(),
            data: data.to_vec(),
        }
    }

    #[test]
    fn estimate_tokens_counts_ascii_and_wide_chars() {
        assert_eq!(estimate_tokens(""), 0);
        // 8 ASCII chars -> 2 tokens.
        assert_eq!(estimate_tokens("12345678"), 2);
        // CJK counts one per char.
        assert_eq!(estimate_tokens("你好世界"), 4);
        // 6 ASCII chars round to 2 tokens; the CJK pair adds one each.
        assert_eq!(estimate_tokens("hello 你好"), 4);
    }

    #[test]
    fn send_estimate_counts_prompt_plus_attachment_text() {
        let text_att = att("note.txt", "text/plain", b"hello world note");
        let tokens = estimate_send_tokens("fix the bug", &[text_att]);
        // prompt ~3 + attachment text ~4 + wrapper + overhead; must be > prompt-only.
        assert!(tokens > estimate_send_tokens("fix the bug", &[]));
        let bare = estimate_send_tokens("fix the bug", &[]);
        assert_eq!(bare, estimate_tokens("fix the bug") + MESSAGE_OVERHEAD_TOKENS);
    }

    #[test]
    fn send_estimate_text_attachment_tracks_file_size() {
        let small = att("a.txt", "text/plain", &[b'x'; 400]);
        let big = att("a.txt", "text/plain", &[b'x'; 40_000]);
        assert!(estimate_attachment_tokens(&big) > estimate_attachment_tokens(&small) * 50);
    }

    #[test]
    fn send_estimate_binary_attachment_is_a_reference_only() {
        let bin = att("blob.bin", "application/octet-stream", &[0u8; 1_000_000]);
        // A 1 MiB binary must not be charged as if its bytes were inlined.
        assert!(estimate_attachment_tokens(&bin) < 200);
    }

    #[test]
    fn image_estimate_uses_png_dimensions() {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        png.extend_from_slice(&[0, 0, 0, 13]); // IHDR length
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&800u32.to_be_bytes()); // width
        png.extend_from_slice(&600u32.to_be_bytes()); // height
        png.extend_from_slice(&[8, 6, 0, 0, 0]);
        let tokens = estimate_attachment_tokens(&att("shot.png", "image/png", &png));
        // 800*600/750 = 640 plus wrapper.
        assert!(tokens > 600 && tokens < 700, "png estimate: {tokens}");
    }

    #[test]
    fn image_estimate_falls_back_to_bytes() {
        let junk = vec![0u8; 75_000];
        let tokens = estimate_attachment_tokens(&att("x.webp", "image/webp", &junk));
        // 75000/750 = 100, clamped up to 85 anyway, plus wrapper.
        assert!(tokens >= 85 && tokens < 200, "webp estimate: {tokens}");
    }

    #[test]
    fn svg_counts_as_text_not_image() {
        let svg = b"<svg xmlns='x'><rect width='1'/></svg>";
        let tokens = estimate_attachment_tokens(&att("icon.svg", "image/svg+xml", svg));
        assert!(tokens < 100, "svg estimate: {tokens}");
    }

    #[test]
    fn meta_estimate_uses_kind_and_size() {
        assert_eq!(
            estimate_attachment_meta_tokens(&serde_json::json!({"kind": "path"})),
            PATH_REF_TOKENS
        );
        assert_eq!(
            estimate_attachment_meta_tokens(&serde_json::json!({"kind": "thread"})),
            THREAD_REF_TOKENS
        );
        assert_eq!(
            estimate_attachment_meta_tokens(&serde_json::json!({"kind": "machine"})),
            MACHINE_REF_TOKENS
        );
        let text = estimate_attachment_meta_tokens(&serde_json::json!({
            "filename": "log.txt",
            "mime": "text/plain",
            "size": 4000,
        }));
        assert_eq!(text, 1000 + BINARY_ATTACHMENT_TOKENS);
        let image = estimate_attachment_meta_tokens(&serde_json::json!({
            "filename": "shot.png",
            "mime": "image/png",
            "size": 10_000_000,
        }));
        // Stored images scale by byte size so a large photo does not
        // collapse to the small flat rate after the send.
        assert_eq!(image, 10_000_000 / 750);
        let small_image = estimate_attachment_meta_tokens(&serde_json::json!({
            "filename": "icon.png",
            "mime": "image/png",
            "size": 1000,
        }));
        assert_eq!(small_image, STORED_IMAGE_TOKENS);
    }

    #[test]
    fn message_estimate_combines_body_and_attachments() {
        let tokens = estimate_message_tokens(400, 0, 0, "[]");
        assert_eq!(tokens, 100 + MESSAGE_OVERHEAD_TOKENS);
        let with_ref = estimate_message_tokens(
            400,
            0,
            0,
            r#"[{"kind":"path","filename":"src/main.rs"}]"#,
        );
        assert_eq!(with_ref, tokens + PATH_REF_TOKENS);
        // parts JSON covers text + thinking + tool calls: take the max, not
        // the sum, so the columns are not double counted.
        let with_parts = estimate_message_tokens(400, 100, 2000, "[]");
        assert_eq!(with_parts, 500 + MESSAGE_OVERHEAD_TOKENS);
    }
}
