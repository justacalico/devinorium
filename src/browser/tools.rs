//! `tools/list` payload: one entry per browser action.
//!
//! `browser_snapshot` is the primary way the agent sees the page: it returns
//! a text view where every interactive element is tagged `[ref=N]`, and the
//! other tools accept that `ref` (or a raw CSS `selector`).

use serde_json::{json, Value};

fn target_props() -> Value {
    json!({
        "ref": {
            "type": "integer",
            "description": "Element ref from the latest browser_snapshot output"
        },
        "selector": {
            "type": "string",
            "description": "CSS selector for the element (use when no ref is available)"
        }
    })
}

pub fn tools() -> Value {
    json!([
        {
            "name": "browser_navigate",
            "description": "Open a URL in the browser. Only http:// and https:// URLs are allowed. Returns the page title, final URL, and a text snapshot.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "The URL to open"}
                },
                "required": ["url"]
            }
        },
        {
            "name": "browser_snapshot",
            "description": "Return a text snapshot of the current page: title, URL, every visible interactive element tagged [ref=N], and the page text. Call this after navigating or whenever the page may have changed; refs from older snapshots become invalid.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "browser_screenshot",
            "description": "Capture the visible viewport as a PNG image.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "browser_click",
            "description": "Click an element by snapshot ref or CSS selector.",
            "inputSchema": {
                "type": "object",
                "properties": target_props()
            }
        },
        {
            "name": "browser_type",
            "description": "Focus an element and type text into it, like a real keyboard. Set submit to also press Enter afterwards.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": {"type": "integer", "description": "Element ref from the latest browser_snapshot output"},
                    "selector": {"type": "string", "description": "CSS selector for the element"},
                    "text": {"type": "string", "description": "Text to type"},
                    "submit": {"type": "boolean", "description": "Press Enter after typing (default false)"}
                },
                "required": ["text"]
            }
        },
        {
            "name": "browser_press_key",
            "description": "Press a single key on the focused element, e.g. Enter, Tab, Escape, Backspace, Delete, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown, or a single character.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "Key name or single character"}
                },
                "required": ["key"]
            }
        },
        {
            "name": "browser_scroll",
            "description": "Scroll the page in a direction by a pixel amount.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
                    "amount": {"type": "integer", "description": "Pixels to scroll (default 720, max 10000)"}
                },
                "required": ["direction"]
            }
        },
        {
            "name": "browser_back",
            "description": "Go back one step in the tab history.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "browser_forward",
            "description": "Go forward one step in the tab history.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "browser_reload",
            "description": "Reload the current page.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "browser_wait",
            "description": "Sleep for a fixed number of milliseconds (max 30000). Use after actions that trigger slow page updates.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ms": {"type": "integer", "description": "Milliseconds to wait (default 1000, max 30000)"}
                }
            }
        },
        {
            "name": "browser_wait_for",
            "description": "Wait until an element matching a CSS selector appears, up to timeout_ms (default 10000, max 30000).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "selector": {"type": "string", "description": "CSS selector to wait for"},
                    "timeout_ms": {"type": "integer", "description": "Max wait in milliseconds"}
                },
                "required": ["selector"]
            }
        },
        {
            "name": "browser_evaluate",
            "description": "Evaluate a JavaScript expression in the page and return its JSON value. Use an IIFE for statements, e.g. (() => document.title)().",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "expression": {"type": "string", "description": "JavaScript expression to evaluate"}
                },
                "required": ["expression"]
            }
        },
        {
            "name": "browser_select",
            "description": "Select option(s) in a <select> element by value, then fires a change event.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": {"type": "integer", "description": "Element ref from the latest browser_snapshot output"},
                    "selector": {"type": "string", "description": "CSS selector for the <select>"},
                    "values": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Option values to select"
                    }
                },
                "required": ["values"]
            }
        },
        {
            "name": "browser_hover",
            "description": "Move the mouse over an element by snapshot ref or CSS selector.",
            "inputSchema": {
                "type": "object",
                "properties": target_props()
            }
        }
    ])
}
