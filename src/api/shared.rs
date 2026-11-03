//! Public read-only view of a shared thread.
//!
//! `GET /shared/<id>` renders the frozen transcript a user published with
//! the thread's Share action. No login is required; the share id is an
//! unguessable token, and revoking the share (or deleting the thread) makes
//! the URL a plain 404.

use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, Router};
use pulldown_cmark::{CowStr, Event, Options, Parser, Tag};

use crate::db::thread_shares::{SharedMessage, ThreadShareRow};
use crate::providers::MessagePart;
use crate::AppState;

/// Public routes that need no session.
pub fn router() -> Router<AppState> {
    Router::new().route("/shared/:id", get(share_page))
}

async fn share_page(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let share = match state.db.get_thread_share(&id).await {
        Ok(Some(share)) => share,
        Ok(None) => {
            return not_found_page();
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Html("server error".to_string()),
            )
                .into_response();
        }
    };

    let messages: Vec<SharedMessage> = serde_json::from_str(&share.snapshot).unwrap_or_default();

    let mut resp = Html(render_share_page(&share, &messages)).into_response();
    let headers = resp.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    // Tighter than the app-wide CSP: the page carries no scripts, images or
    // fonts, so a defense-in-depth policy pins it to inline styles only.
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("default-src 'none'; style-src 'unsafe-inline'"),
    );
    resp
}

fn not_found_page() -> Response {
    let html = page_shell(
        "Share not found",
        "Share not found",
        "<p class=\"empty\">This shared conversation does not exist or was revoked.</p>",
    );
    (StatusCode::NOT_FOUND, Html(html)).into_response()
}

fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// A `javascript:`/`data:`/`vbscript:` href in published markdown would run
/// in this origin on click, so only safe schemes and relative links survive.
fn sanitize_link_url(url: &str) -> CowStr<'static> {
    let trimmed = url.trim();
    let lower = trimmed.to_ascii_lowercase();
    let safe = (lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("mailto:")
        || lower.starts_with('#')
        || (lower.starts_with('/') && !lower.starts_with("//") && !lower.starts_with("/\\"))
        || match lower.find(':') {
            Some(colon) => lower[..colon].contains('/'),
            None => true, // relative path with no scheme
        })
        && !lower.starts_with('\\');
    if safe {
        CowStr::from(trimmed.to_string())
    } else {
        CowStr::from("#")
    }
}

/// Render markdown to sanitized HTML: raw HTML blocks are shown literally
/// instead of executed, and unsafe link targets are neutralized.
fn render_markdown(input: &str) -> String {
    let options =
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    let parser = Parser::new_ext(input, options).map(|event| match event {
        Event::Html(html) | Event::InlineHtml(html) => Event::Text(html),
        Event::Start(Tag::Link {
            link_type,
            dest_url,
            title,
            id,
        }) => Event::Start(Tag::Link {
            link_type,
            dest_url: sanitize_link_url(&dest_url),
            title,
            id,
        }),
        Event::Start(Tag::Image {
            link_type,
            dest_url,
            title,
            id,
        }) => Event::Start(Tag::Image {
            link_type,
            dest_url: sanitize_link_url(&dest_url),
            title,
            id,
        }),
        other => other,
    });
    let mut out = String::with_capacity(input.len() * 2);
    pulldown_cmark::html::push_html(&mut out, parser);
    out
}

fn render_tool_call(payload: &crate::providers::ToolCallEvent) -> String {
    let mut out = String::from("<details class=\"tool\"><summary>");
    out.push_str("<span class=\"tool-name\">");
    out.push_str(&escape_html(&payload.title));
    out.push_str("</span>");
    if !payload.kind.is_empty() {
        out.push_str("<span class=\"tool-kind\">");
        out.push_str(&escape_html(&payload.kind));
        out.push_str("</span>");
    }
    if !payload.status.is_empty() {
        out.push_str("<span class=\"tool-status status-");
        out.push_str(&escape_html(&payload.status));
        out.push_str("\">");
        out.push_str(&escape_html(&payload.status));
        out.push_str("</span>");
    }
    out.push_str("</summary>");
    if let Some(command) = payload.command.as_deref().filter(|c| !c.is_empty()) {
        out.push_str("<pre class=\"tool-command\">");
        out.push_str(&escape_html(command));
        out.push_str("</pre>");
    }
    let output = payload
        .output
        .as_deref()
        .or(payload.output_preview.as_deref())
        .unwrap_or("");
    if !output.is_empty() {
        out.push_str("<pre class=\"tool-output\">");
        out.push_str(&escape_html(output));
        out.push_str("</pre>");
    }
    out.push_str("</details>");
    out
}

fn render_thinking(text: &str) -> String {
    let mut out = String::from("<details class=\"thinking\"><summary>Thinking</summary><pre>");
    out.push_str(&escape_html(text));
    out.push_str("</pre></details>");
    out
}

fn attachment_names(attachments: &serde_json::Value) -> Vec<String> {
    attachments
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|a| a.get("filename").and_then(|f| f.as_str()))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn short_timestamp(created_at: &str) -> String {
    // "YYYY-MM-DDTHH:MM:SS.mmmZ" -> "YYYY-MM-DD HH:MM"
    match created_at.get(..16) {
        Some(prefix) => prefix.replacen('T', " ", 1),
        None => created_at.to_string(),
    }
}

fn render_message(msg: &SharedMessage, agent_label: &str) -> String {
    let (css, label) = match msg.role.as_str() {
        "user" => ("user", "You"),
        "error" => ("error", "Error"),
        "system" => ("system", "System"),
        _ => ("assistant", agent_label),
    };
    let mut out =
        format!("<section class=\"msg {css}\"><header><span class=\"role\">{label}</span>");
    let ts = short_timestamp(&msg.created_at);
    if !ts.is_empty() {
        out.push_str("<time>");
        out.push_str(&escape_html(&ts));
        out.push_str("</time>");
    }
    out.push_str("</header>");

    let names = attachment_names(&msg.attachments);
    if !names.is_empty() {
        out.push_str("<p class=\"attachments\">Attachments: ");
        out.push_str(&escape_html(&names.join(", ")));
        out.push_str("</p>");
    }

    // Parts carry the ordered truth, except when the stored message was
    // truncated — then only tool calls survive and the text lives in
    // `content`/`thinking`. Either way, tool calls still render in order.
    let has_text_parts = msg
        .parts
        .iter()
        .any(|p| matches!(p, MessagePart::Text { .. } | MessagePart::Thinking { .. }));
    let mut thinking_open = false;
    if has_text_parts {
        for part in &msg.parts {
            match part {
                MessagePart::Text { content } => {
                    if thinking_open {
                        out.push_str("</pre></details>");
                        thinking_open = false;
                    }
                    if !content.is_empty() {
                        out.push_str("<div class=\"body\">");
                        out.push_str(&render_markdown(content));
                        out.push_str("</div>");
                    }
                }
                MessagePart::Thinking { content } => {
                    if !content.is_empty() {
                        if !thinking_open {
                            out.push_str(
                                "<details class=\"thinking\"><summary>Thinking</summary><pre>",
                            );
                            thinking_open = true;
                        } else {
                            out.push_str("\n\n");
                        }
                        out.push_str(&escape_html(content));
                    }
                }
                MessagePart::ToolCall { payload } => {
                    if thinking_open {
                        out.push_str("</pre></details>");
                        thinking_open = false;
                    }
                    out.push_str(&render_tool_call(payload));
                }
            }
        }
        if thinking_open {
            out.push_str("</pre></details>");
        }
    } else {
        if let Some(thinking) = msg.thinking.as_deref().filter(|t| !t.is_empty()) {
            out.push_str(&render_thinking(thinking));
        }
        if msg.role == "error" {
            out.push_str("<pre class=\"error-body\">");
            out.push_str(&escape_html(&msg.content));
            out.push_str("</pre>");
        } else if !msg.content.is_empty() {
            out.push_str("<div class=\"body\">");
            out.push_str(&render_markdown(&msg.content));
            out.push_str("</div>");
        }
        for part in &msg.parts {
            if let MessagePart::ToolCall { payload } = part {
                out.push_str(&render_tool_call(payload));
            }
        }
    }

    if msg.truncated {
        out.push_str("<p class=\"truncated\">Message truncated.</p>");
    }
    out.push_str("</section>");
    out
}

fn page_shell(title: &str, heading: &str, body: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head>\
<meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<meta name=\"referrer\" content=\"no-referrer\">\
<title>{title}</title>\
<style>{PAGE_CSS}</style>\
</head><body><main><h1 class=\"brand\">{heading}</h1>{body}</main></body></html>",
    )
}

fn render_share_page(share: &ThreadShareRow, messages: &[SharedMessage]) -> String {
    let agent_label = crate::providers::provider_name(&share.provider_id)
        .map(escape_html)
        .unwrap_or_else(|| "Assistant".to_string());

    let mut body = String::new();
    body.push_str("<p class=\"meta\">Shared conversation &middot; ");
    body.push_str(&escape_html(&share.title));
    body.push_str(" &middot; ");
    body.push_str(&escape_html(&agent_label));
    let ts = short_timestamp(&share.created_at);
    if !ts.is_empty() {
        body.push_str(" &middot; ");
        body.push_str(&escape_html(&ts));
    }
    body.push_str("</p>");

    if messages.is_empty() {
        body.push_str("<p class=\"empty\">This shared conversation is empty.</p>");
    }
    for msg in messages {
        body.push_str(&render_message(msg, &agent_label));
    }
    body.push_str("<footer>Published by Devinorium</footer>");

    page_shell(
        &format!("{} — Shared conversation", escape_html(&share.title)),
        &escape_html(&share.title),
        &body,
    )
}

const PAGE_CSS: &str = "\
:root{color-scheme:dark}\
*{box-sizing:border-box}\
body{margin:0;background:#131314;color:#e3e3e3;font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;line-height:1.55}\
main{max-width:820px;margin:0 auto;padding:32px 20px 64px}\
h1.brand{font-size:1.4rem;margin:0 0 4px}\
.meta{color:#9aa0a6;font-size:.85rem;margin:0 0 28px}\
.msg{border:1px solid #2a2b2e;border-radius:12px;padding:14px 16px;margin:0 0 14px;background:#1b1b1e}\
.msg.user{background:#1e2530;border-color:#2d3a4d}\
.msg.error{border-color:#5a3038;background:#261a1d}\
.msg header{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px}\
.role{font-weight:600;font-size:.8rem;text-transform:uppercase;letter-spacing:.04em;color:#9ab3d4}\
.msg.user .role{color:#8ab4f8}\
.msg.error .role{color:#f28b82}\
time{color:#9aa0a6;font-size:.75rem}\
.body{overflow-wrap:break-word}\
.body pre{white-space:pre-wrap;background:#131314;border:1px solid #2a2b2e;border-radius:8px;padding:10px;overflow-x:auto}\
.body code{font-family:ui-monospace,'Cascadia Code','JetBrains Mono',monospace;font-size:.9em}\
.body :not(pre)>code{background:#2a2b2e;border-radius:4px;padding:1px 4px}\
.body table{border-collapse:collapse}\
.body th,.body td{border:1px solid #2a2b2e;padding:4px 10px}\
.body a{color:#8ab4f8}\
details{margin:8px 0}\
details summary{cursor:pointer;color:#9aa0a6;font-size:.85rem}\
details.thinking pre{white-space:pre-wrap;color:#9aa0a6;font-size:.85rem;margin:8px 0 0}\
details.tool{border:1px solid #2a2b2e;border-radius:8px;padding:8px 12px}\
.tool-name{font-weight:600;color:#e3e3e3}\
.tool-kind{color:#9aa0a6;margin-left:8px}\
.tool-status{margin-left:8px;border-radius:10px;padding:1px 8px;font-size:.75rem;background:#2a2b2e;color:#9aa0a6}\
.status-completed,.status-done,.status-success{background:#1d3a28;color:#81c995}\
.status-failed,.status-error{background:#3a2427;color:#f28b82}\
.status-running,.status-in_progress{background:#2f3b52;color:#a8c7fa}\
.tool-command,.tool-output,.error-body{white-space:pre-wrap;background:#131314;border:1px solid #2a2b2e;border-radius:8px;padding:10px;font-size:.85rem;overflow-x:auto;margin:8px 0 0;font-family:ui-monospace,'Cascadia Code','JetBrains Mono',monospace}\
.error-body{color:#f28b82}\
.attachments{color:#9aa0a6;font-size:.8rem;margin:0 0 8px}\
.truncated{color:#9aa0a6;font-size:.8rem;font-style:italic;margin:8px 0 0}\
.msg.system .role{color:#9aa0a6}\
.empty{color:#9aa0a6}\
footer{margin-top:40px;color:#6a7076;font-size:.75rem;text-align:center}\
";

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(role: &str, content: &str) -> SharedMessage {
        SharedMessage {
            role: role.into(),
            content: content.into(),
            thinking: None,
            parts: vec![],
            attachments: serde_json::json!([]),
            model: String::new(),
            truncated: false,
            created_at: "2024-01-01T12:34:56.000Z".into(),
        }
    }

    #[test]
    fn escape_html_covers_all_specials() {
        assert_eq!(
            escape_html("<a href=\"x\">&'</a>"),
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;"
        );
    }

    #[test]
    fn markdown_renders_basics_and_escapes_raw_html() {
        let html = render_markdown("# Hi\n\n**bold** and `code`\n\n<script>alert(1)</script>");
        assert!(html.contains("<h1>Hi</h1>"));
        assert!(html.contains("<strong>bold</strong>"));
        assert!(html.contains("<code>code</code>"));
        assert!(html.contains("&lt;script&gt;"), "raw html must be escaped");
        assert!(!html.contains("<script>"));
    }

    #[test]
    fn markdown_neutralizes_javascript_links() {
        let html = render_markdown("[x](javascript:alert(1)) [ok](https://a.b) [rel](/p)");
        assert!(!html.contains("javascript:"));
        assert!(html.contains("href=\"#\""));
        assert!(html.contains("href=\"https://a.b\""));
        assert!(html.contains("href=\"/p\""));
    }

    #[test]
    fn share_page_renders_roles_and_tool_calls() {
        let share = ThreadShareRow {
            id: "sh-1".into(),
            thread_id: "t".into(),
            user_id: 1,
            title: "Fix the bug".into(),
            provider_id: "devin-cli".into(),
            snapshot: "[]".into(),
            created_at: "2024-02-03T04:05:06.000Z".into(),
        };
        let tool = SharedMessage {
            parts: vec![
                MessagePart::thinking("thinking hard"),
                MessagePart::tool_call(crate::providers::ToolCallEvent {
                    id: "tc1".into(),
                    title: "Run tests".into(),
                    kind: "execute".into(),
                    status: "completed".into(),
                    command: Some("cargo test".into()),
                    output: Some("all green".into()),
                    output_preview: None,
                    changed_files: vec![],
                    diffs: vec![],
                }),
                MessagePart::text("done"),
            ],
            ..msg("assistant", "")
        };
        let html = render_share_page(&share, &[msg("user", "hi"), tool]);
        assert!(html.contains("Fix the bug"));
        assert!(html.contains("Devin CLI"));
        assert!(html.contains(">You<"));
        assert!(html.contains("thinking hard"));
        assert!(html.contains("Run tests"));
        assert!(html.contains("cargo test"));
        assert!(html.contains("done"));
        assert!(html.contains("2024-02-03 04:05"));
    }

    #[test]
    fn share_page_escapes_title_and_content_fallbacks() {
        let share = ThreadShareRow {
            id: "sh-1".into(),
            thread_id: "t".into(),
            user_id: 1,
            title: "<img onerror=x>".into(),
            provider_id: "unknown".into(),
            snapshot: "[]".into(),
            created_at: String::new(),
        };
        let html = render_share_page(&share, &[msg("user", "<b>raw</b>")]);
        assert!(!html.contains("<img onerror"));
        assert!(html.contains("Assistant"));
        // Plain content goes through markdown, so markup chars are treated
        // as markdown and raw html is escaped, never executed.
        assert!(html.contains("&lt;b&gt;raw&lt;/b&gt;"));
    }

    #[test]
    fn truncated_message_keeps_text_and_tool_calls() {
        let mut m = msg("assistant", "the visible reply text");
        m.parts = vec![MessagePart::tool_call(crate::providers::ToolCallEvent {
            id: "tc1".into(),
            title: "Edit file".into(),
            kind: "edit".into(),
            status: "completed".into(),
            command: None,
            output: None,
            output_preview: None,
            changed_files: vec![],
            diffs: vec![],
        })];
        let html = render_message(&m, "Assistant");
        assert!(html.contains("the visible reply text"));
        assert!(html.contains("Edit file"));
    }

    #[test]
    fn attachments_list_filenames_only() {
        let mut m = msg("user", "see files");
        m.attachments = serde_json::json!([
            {"filename": "a.png", "mime": "image/png", "size": 3, "index": 0},
            {"path": "/secret/dir", "is_dir": true}
        ]);
        let html = render_message(&m, "Assistant");
        assert!(html.contains("a.png"));
        assert!(!html.contains("/secret/dir"));
    }
}
