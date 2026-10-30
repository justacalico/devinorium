//! Tool argument parsing and validation.
//!
//! Every `tools/call` arrives as `{name, arguments}`; this module turns that
//! into a typed [`Action`] or a user-facing error string (the MCP `isError`
//! result), so the engine only ever sees valid input.

use serde_json::Value;

/// Hard caps so a runaway agent cannot wedge the browser or balloon a reply.
pub const MAX_URL_LEN: usize = 8192;
pub const MAX_SELECTOR_LEN: usize = 2048;
pub const MAX_TYPE_LEN: usize = 32 * 1024;
pub const MAX_EXPR_LEN: usize = 64 * 1024;
pub const MAX_WAIT_MS: u64 = 30_000;
pub const DEFAULT_WAIT_MS: u64 = 10_000;
pub const MAX_SCROLL_PX: u32 = 10_000;
pub const DEFAULT_SCROLL_PX: u32 = 720;
pub const MAX_SELECT_VALUES: usize = 32;

/// How a click/type/hover/select tool locates its element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// Element ref from the last `browser_snapshot` (`[ref=3]` lines).
    Ref(u64),
    /// A CSS selector the agent supplies directly.
    Selector(String),
}

impl Target {
    /// The CSS selector the engine should query. Refs are materialized as
    /// `data-dvref` attributes by the snapshot script.
    pub fn to_css(&self) -> String {
        match self {
            Target::Ref(n) => format!("[data-dvref=\"{n}\"]"),
            Target::Selector(s) => s.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollDirection {
    Up,
    Down,
    Left,
    Right,
}

impl ScrollDirection {
    pub fn delta(self, amount: u32) -> (i64, i64) {
        let px = i64::from(amount);
        match self {
            ScrollDirection::Up => (0, -px),
            ScrollDirection::Down => (0, px),
            ScrollDirection::Left => (-px, 0),
            ScrollDirection::Right => (px, 0),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Navigate {
        url: String,
    },
    Snapshot,
    Screenshot,
    Click {
        target: Target,
    },
    Type {
        target: Target,
        text: String,
        submit: bool,
    },
    PressKey {
        key: String,
    },
    Scroll {
        direction: ScrollDirection,
        amount: u32,
    },
    Back,
    Forward,
    Reload,
    WaitFor {
        selector: String,
        timeout_ms: u64,
    },
    Wait {
        ms: u64,
    },
    Evaluate {
        expression: String,
    },
    Select {
        target: Target,
        values: Vec<String>,
    },
    Hover {
        target: Target,
    },
}

impl Action {
    /// The element target this action operates on, when it has one.
    pub fn target(&self) -> Option<&Target> {
        match self {
            Action::Click { target }
            | Action::Type { target, .. }
            | Action::Select { target, .. }
            | Action::Hover { target } => Some(target),
            _ => None,
        }
    }

    /// Whether this action can mutate the DOM or navigate. After such an
    /// action the engine bumps its epoch, which invalidates snapshot refs.
    pub fn invalidates_snapshot(&self) -> bool {
        matches!(
            self,
            Action::Navigate { .. }
                | Action::Click { .. }
                | Action::Type { .. }
                | Action::PressKey { .. }
                | Action::Back
                | Action::Forward
                | Action::Reload
                | Action::Evaluate { .. }
                | Action::Select { .. }
        )
    }
}

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing or invalid `{key}` argument"))
}

fn target_arg(args: &Value) -> Result<Target, String> {
    let has_ref = args.get("ref").is_some();
    let has_sel = args.get("selector").is_some();
    match (has_ref, has_sel) {
        (true, true) => Err("pass either `ref` or `selector`, not both".into()),
        (true, false) => {
            let n = args["ref"]
                .as_u64()
                .ok_or_else(|| "`ref` must be a positive integer".to_string())?;
            Ok(Target::Ref(n))
        }
        (false, true) => {
            let sel = str_arg(args, "selector")?.trim();
            if sel.is_empty() {
                return Err("`selector` must not be empty".into());
            }
            if sel.len() > MAX_SELECTOR_LEN {
                return Err("`selector` is too long".into());
            }
            Ok(Target::Selector(sel.to_string()))
        }
        (false, false) => Err("missing `ref` or `selector` argument".into()),
    }
}

/// Only http(s) pages may be loaded. `file://`, `chrome://`, `data:` and
/// friends would let the agent escape into the host filesystem or browser
/// internals; credentials in the URL are refused as well.
pub fn validate_url(raw: &str) -> Result<String, String> {
    let url = raw.trim();
    if url.is_empty() {
        return Err("`url` must not be empty".into());
    }
    if url.len() > MAX_URL_LEN {
        return Err("`url` is too long".into());
    }
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("https://") || lower.starts_with("http://")) {
        return Err("only http:// and https:// urls can be opened".into());
    }
    let rest = &url[url.find("://").unwrap() + 3..];
    if rest.starts_with('@') || rest.split('/').next().is_some_and(|h| h.contains('@')) {
        return Err("urls with embedded credentials are not allowed".into());
    }
    Ok(url.to_string())
}

fn key_arg(args: &Value) -> Result<String, String> {
    let key = str_arg(args, "key")?.trim();
    if key.is_empty() {
        return Err("`key` must not be empty".into());
    }
    if key.len() > 64 {
        return Err("`key` is too long".into());
    }
    Ok(key.to_string())
}

fn positive_ms(args: &Value, key: &str, default: u64) -> Result<u64, String> {
    match args.get(key) {
        None => Ok(default),
        Some(v) => v
            .as_u64()
            .filter(|n| *n > 0 && *n <= MAX_WAIT_MS)
            .ok_or_else(|| format!("`{key}` must be between 1 and {MAX_WAIT_MS}")),
    }
}

/// Map a `tools/call` name + arguments onto an [`Action`]. `args` may be
/// `Value::Null` when the caller omitted `arguments`; the getters then fail
/// with the usual "missing argument" errors.
pub fn parse(name: &str, args: &Value) -> Result<Action, String> {
    match name {
        "browser_navigate" => Ok(Action::Navigate {
            url: validate_url(str_arg(args, "url")?)?,
        }),
        "browser_snapshot" => Ok(Action::Snapshot),
        "browser_screenshot" => Ok(Action::Screenshot),
        "browser_click" => Ok(Action::Click {
            target: target_arg(args)?,
        }),
        "browser_type" => {
            let text = str_arg(args, "text")?;
            if text.len() > MAX_TYPE_LEN {
                return Err("`text` is too long".into());
            }
            let submit = args.get("submit").and_then(Value::as_bool).unwrap_or(false);
            Ok(Action::Type {
                target: target_arg(args)?,
                text: text.to_string(),
                submit,
            })
        }
        "browser_press_key" => Ok(Action::PressKey {
            key: key_arg(args)?,
        }),
        "browser_scroll" => {
            let direction = match str_arg(args, "direction")? {
                "up" => ScrollDirection::Up,
                "down" => ScrollDirection::Down,
                "left" => ScrollDirection::Left,
                "right" => ScrollDirection::Right,
                other => return Err(format!("unknown scroll direction `{other}`")),
            };
            let amount = match args.get("amount") {
                None => DEFAULT_SCROLL_PX,
                Some(v) => v
                    .as_u64()
                    .and_then(|n| u32::try_from(n).ok())
                    .filter(|n| *n > 0 && *n <= MAX_SCROLL_PX)
                    .ok_or_else(|| format!("`amount` must be between 1 and {MAX_SCROLL_PX}"))?,
            };
            Ok(Action::Scroll { direction, amount })
        }
        "browser_back" => Ok(Action::Back),
        "browser_forward" => Ok(Action::Forward),
        "browser_reload" => Ok(Action::Reload),
        "browser_wait_for" => {
            let selector = str_arg(args, "selector")?.trim();
            if selector.is_empty() {
                return Err("`selector` must not be empty".into());
            }
            if selector.len() > MAX_SELECTOR_LEN {
                return Err("`selector` is too long".into());
            }
            Ok(Action::WaitFor {
                selector: selector.to_string(),
                timeout_ms: positive_ms(args, "timeout_ms", DEFAULT_WAIT_MS)?,
            })
        }
        "browser_wait" => Ok(Action::Wait {
            ms: positive_ms(args, "ms", 1000)?,
        }),
        "browser_evaluate" => {
            let expr = str_arg(args, "expression")?;
            if expr.trim().is_empty() {
                return Err("`expression` must not be empty".into());
            }
            if expr.len() > MAX_EXPR_LEN {
                return Err("`expression` is too long".into());
            }
            Ok(Action::Evaluate {
                expression: expr.to_string(),
            })
        }
        "browser_select" => {
            let values = args
                .get("values")
                .and_then(Value::as_array)
                .ok_or_else(|| "missing or invalid `values` argument".to_string())?;
            if values.is_empty() || values.len() > MAX_SELECT_VALUES {
                return Err(format!("`values` must have 1..{MAX_SELECT_VALUES} entries"));
            }
            let values = values
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .ok_or_else(|| "`values` entries must be strings".to_string())
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Action::Select {
                target: target_arg(args)?,
                values,
            })
        }
        "browser_hover" => Ok(Action::Hover {
            target: target_arg(args)?,
        }),
        other => Err(format!("unknown tool `{other}`")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn navigate_accepts_http_and_https() {
        let a = parse("browser_navigate", &json!({"url": "https://example.com/x"})).unwrap();
        assert_eq!(
            a,
            Action::Navigate {
                url: "https://example.com/x".into()
            }
        );
        assert!(parse("browser_navigate", &json!({"url": "http://intranet.local"})).is_ok());
    }

    #[test]
    fn navigate_rejects_non_web_schemes_and_credentials() {
        for url in [
            "file:///etc/passwd",
            "chrome://settings",
            "data:text/html,<h1>x</h1>",
            "javascript:alert(1)",
            "about:blank",
            "ftp://host/file",
            "example.com/no-scheme",
            "https://user:pass@example.com/",
            "",
        ] {
            assert!(
                parse("browser_navigate", &json!({"url": url})).is_err(),
                "{url} should be rejected"
            );
        }
    }

    #[test]
    fn target_requires_ref_xor_selector() {
        assert_eq!(target_arg(&json!({"ref": 3})).unwrap(), Target::Ref(3));
        assert_eq!(
            target_arg(&json!({"selector": "#btn"})).unwrap(),
            Target::Selector("#btn".into())
        );
        assert!(target_arg(&json!({"ref": 1, "selector": "a"})).is_err());
        assert!(target_arg(&json!({})).is_err());
        assert!(target_arg(&json!({"ref": "x"})).is_err());
        assert!(target_arg(&json!({"selector": "  "})).is_err());
    }

    #[test]
    fn ref_targets_materialize_as_dvref_attribute() {
        assert_eq!(Target::Ref(7).to_css(), "[data-dvref=\"7\"]");
        assert_eq!(Target::Selector("a.b".into()).to_css(), "a.b");
    }

    #[test]
    fn type_parses_text_and_submit() {
        let a = parse(
            "browser_type",
            &json!({"ref": 2, "text": "abc", "submit": true}),
        )
        .unwrap();
        assert_eq!(
            a,
            Action::Type {
                target: Target::Ref(2),
                text: "abc".into(),
                submit: true
            }
        );
        let a = parse("browser_type", &json!({"selector": "input", "text": "x"})).unwrap();
        assert!(matches!(a, Action::Type { submit: false, .. }));
        assert!(parse("browser_type", &json!({"ref": 1})).is_err());
    }

    #[test]
    fn scroll_defaults_and_validation() {
        let a = parse("browser_scroll", &json!({"direction": "down"})).unwrap();
        assert_eq!(
            a,
            Action::Scroll {
                direction: ScrollDirection::Down,
                amount: DEFAULT_SCROLL_PX
            }
        );
        assert!(matches!(
            parse(
                "browser_scroll",
                &json!({"direction": "left", "amount": 100})
            )
            .unwrap(),
            Action::Scroll {
                direction: ScrollDirection::Left,
                amount: 100
            }
        ));
        for bad in [
            json!({"direction": "sideways"}),
            json!({"direction": "up", "amount": 0}),
            json!({"direction": "up", "amount": MAX_SCROLL_PX as u64 + 1}),
        ] {
            assert!(parse("browser_scroll", &bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn wait_caps_at_max_and_wait_for_requires_selector() {
        assert!(matches!(
            parse("browser_wait", &json!({})).unwrap(),
            Action::Wait { ms: 1000 }
        ));
        assert!(parse("browser_wait", &json!({"ms": MAX_WAIT_MS + 1})).is_err());
        assert!(matches!(
            parse("browser_wait_for", &json!({"selector": ".x"})).unwrap(),
            Action::WaitFor {
                timeout_ms: DEFAULT_WAIT_MS,
                ..
            }
        ));
        assert!(parse("browser_wait_for", &json!({})).is_err());
    }

    #[test]
    fn evaluate_select_and_misc_parse() {
        assert!(matches!(
            parse("browser_evaluate", &json!({"expression": "1+1"})).unwrap(),
            Action::Evaluate { .. }
        ));
        assert!(parse("browser_evaluate", &json!({"expression": " "})).is_err());
        let sel = parse(
            "browser_select",
            &json!({"selector": "select", "values": ["a", "b"]}),
        )
        .unwrap();
        assert!(matches!(sel, Action::Select { .. }));
        assert!(parse("browser_select", &json!({"selector": "s", "values": []})).is_err());
        assert!(parse("browser_select", &json!({"selector": "s", "values": [1]})).is_err());
        for (name, want) in [
            ("browser_snapshot", Action::Snapshot),
            ("browser_screenshot", Action::Screenshot),
            ("browser_back", Action::Back),
            ("browser_forward", Action::Forward),
            ("browser_reload", Action::Reload),
            (
                "browser_press_key",
                Action::PressKey {
                    key: "Enter".into(),
                },
            ),
            (
                "browser_click",
                Action::Click {
                    target: Target::Ref(1),
                },
            ),
            (
                "browser_hover",
                Action::Hover {
                    target: Target::Ref(1),
                },
            ),
        ] {
            let args = if name == "browser_press_key" {
                json!({"key": "Enter"})
            } else if matches!(name, "browser_click" | "browser_hover") {
                json!({"ref": 1})
            } else {
                json!({})
            };
            assert_eq!(parse(name, &args).unwrap(), want, "{name}");
        }
        assert!(parse("browser_hack", &json!({})).is_err());
        assert!(parse("browser_press_key", &json!({"key": ""})).is_err());
    }

    #[test]
    fn mutating_actions_invalidate_snapshot_but_reads_do_not() {
        for (name, args, expected) in [
            ("browser_navigate", json!({"url": "http://a"}), true),
            ("browser_click", json!({"ref": 1}), true),
            ("browser_press_key", json!({"key": "Tab"}), true),
            ("browser_back", json!({}), true),
            ("browser_evaluate", json!({"expression": "1"}), true),
            ("browser_snapshot", json!({}), false),
            ("browser_screenshot", json!({}), false),
            ("browser_scroll", json!({"direction": "down"}), false),
            ("browser_hover", json!({"ref": 1}), false),
            ("browser_wait", json!({}), false),
            ("browser_wait_for", json!({"selector": "a"}), false),
        ] {
            assert_eq!(
                parse(name, &args).unwrap().invalidates_snapshot(),
                expected,
                "{name}"
            );
        }
    }
}
