//! The headless-Chromium backend behind the MCP tools.
//!
//! [`Engine`] is a small trait so the stdio server can be unit-tested with a
//! fake; [`ChromiumEngine`] is the real implementation driving a single tab
//! through the Chrome DevTools Protocol.

use std::time::Duration;

use async_trait::async_trait;
use chromiumoxide::cdp::browser_protocol::page::CaptureScreenshotFormat;
use chromiumoxide::page::ScreenshotParams;
use chromiumoxide::{Browser, BrowserConfig, Element, Page};
use futures::StreamExt;
use serde_json::Value;

use super::action::{Action, Target};
use super::{find_browser_binary, ToolContent};

/// How long a navigation may take before the tool reports a timeout.
const NAV_TIMEOUT: Duration = Duration::from_secs(30);
/// Any other CDP round-trip.
const OP_TIMEOUT: Duration = Duration::from_secs(15);
/// Snapshot output caps: element rows and page-text characters.
const MAX_SNAPSHOT_ELEMENTS: usize = 512;
const MAX_SNAPSHOT_TEXT: usize = 8_000;
/// `browser_evaluate` result cap in JSON characters.
const MAX_EVAL_OUTPUT: usize = 32 * 1024;
/// Pause after history navigation / reload before reporting state.
const SETTLE_MS: u64 = 800;
/// Viewport reported to the page.
const VIEWPORT: (u32, u32) = (1280, 800);

/// Content the engine hands back to the MCP layer.
#[async_trait]
pub trait Engine: Send {
    async fn perform(&mut self, action: &Action) -> Result<Vec<ToolContent>, String>;

    /// Whether the underlying browser is still usable. The stdio server
    /// relaunches the engine when this returns false.
    fn alive(&mut self) -> bool {
        true
    }
}

/// Tracks DOM versions for snapshot-ref staleness. Every mutating action
/// bumps `epoch`; `browser_snapshot` stamps the current epoch. Ref-based
/// tools must be checked against the pre-action epoch, so ordering is:
/// check target, then bump, then run.
#[derive(Debug, Default)]
struct SnapshotClock {
    epoch: u64,
    snapshot_epoch: Option<u64>,
}

impl SnapshotClock {
    fn check(&self, target: &Target) -> Result<(), String> {
        if let Target::Ref(_) = target {
            match self.snapshot_epoch {
                Some(e) if e == self.epoch => Ok(()),
                Some(_) => Err(
                    "the page changed since the last snapshot; call browser_snapshot again".into(),
                ),
                None => Err("no snapshot yet; call browser_snapshot first".into()),
            }
        } else {
            Ok(())
        }
    }

    fn stamp(&mut self) {
        self.snapshot_epoch = Some(self.epoch);
    }

    fn bump(&mut self) {
        self.epoch += 1;
    }
}

fn text(s: impl Into<String>) -> Vec<ToolContent> {
    vec![ToolContent::Text(s.into())]
}

/// Cut `s` at `max` bytes without panicking mid-char (str::truncate panics
/// off-boundary). Assumes `s` is longer than `max`.
fn truncate_utf8(s: &mut String, max: usize) {
    let mut end = max.min(s.len());
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s.truncate(end);
}

/// Page context reported after most actions so the agent always knows where
/// it ended up.
async fn page_header(page: &Page, epoch: u64) -> String {
    let url = page.url().await.ok().flatten().unwrap_or_default();
    let title = page.get_title().await.ok().flatten().unwrap_or_default();
    format!("Page: {title}\nURL: {url}\nPage epoch: {epoch}")
}

/// A browser subprocess plus its single working tab.
pub struct ChromiumEngine {
    /// Dropping it kills the spawned chromium via kill_on_drop.
    browser: Browser,
    page: Page,
    handler: tokio::task::JoinHandle<()>,
    _profile: tempfile::TempDir,
    clock: SnapshotClock,
}

impl ChromiumEngine {
    pub async fn launch() -> Result<Self, String> {
        let binary = find_browser_binary().ok_or_else(|| {
            "no Chromium/Chrome binary found; install one or set DEVINORIUM_BROWSER_BINARY"
                .to_string()
        })?;

        let profile = tempfile::tempdir()
            .map_err(|e| format!("could not create browser profile dir: {e}"))?;

        let mut builder = BrowserConfig::builder()
            .chrome_executable(&binary)
            .new_headless_mode()
            .window_size(VIEWPORT.0, VIEWPORT.1)
            .user_data_dir(profile.path())
            .request_timeout(OP_TIMEOUT)
            .args([
                "--disable-dev-shm-usage",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-default-apps",
                "--disable-sync",
                "--mute-audio",
                "--no-first-run",
                "--no-default-browser-check",
                "--metrics-recording-only",
                "--disable-features=Translate,OptimizationHints",
            ]);
        if running_as_root() {
            builder = builder.no_sandbox();
        }
        let config = builder
            .build()
            .map_err(|e| format!("invalid browser configuration: {e}"))?;

        let (browser, mut handler) = Browser::launch(config)
            .await
            .map_err(|e| format!("could not launch {}: {e}", binary.display()))?;
        let handler = tokio::spawn(async move {
            while let Some(ev) = handler.next().await {
                if let Err(e) = ev {
                    tracing::debug!(error = %e, "browser handler event error");
                }
            }
        });

        let page = browser
            .new_page("about:blank")
            .await
            .map_err(|e| format!("could not open a tab: {e}"))?;

        Ok(Self {
            browser,
            page,
            handler,
            _profile: profile,
            clock: SnapshotClock::default(),
        })
    }

    async fn element(&self, target: &Target) -> Result<Element, String> {
        let css = target.to_css();
        match tokio::time::timeout(OP_TIMEOUT, self.page.find_element(css)).await {
            Ok(Ok(el)) => Ok(el),
            Ok(Err(e)) => Err(match target {
                Target::Ref(n) => format!(
                    "element ref {n} not found; the page may have changed, call browser_snapshot again ({e})"
                ),
                Target::Selector(s) => format!("no element matches selector `{s}` ({e})"),
            }),
            Err(_) => Err("element lookup timed out".into()),
        }
    }

    async fn eval<T: serde::de::DeserializeOwned>(&self, expr: &str) -> Result<T, String> {
        match tokio::time::timeout(OP_TIMEOUT, self.page.evaluate(expr)).await {
            Ok(Ok(res)) => res
                .into_value::<T>()
                .map_err(|e| format!("unexpected evaluate result: {e}")),
            Ok(Err(e)) => Err(format!("evaluation failed: {e}")),
            Err(_) => Err("evaluation timed out".into()),
        }
    }

    /// Snapshot the DOM: tag every visible interactive element with
    /// `data-dvref` and return title/url/elements/body text as JSON.
    async fn snapshot_json(&self) -> Result<Value, String> {
        let script = format!(
            "({})({})",
            SNAPSHOT_JS,
            serde_json::json!({
                "attr": "data-dvref",
                "max": MAX_SNAPSHOT_ELEMENTS,
                "textMax": MAX_SNAPSHOT_TEXT,
            })
        );
        self.eval(&script).await
    }

    fn format_snapshot(&self, v: &Value) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "Page: {}\nURL: {}\nSnapshot epoch: {}\n\n",
            v["title"].as_str().unwrap_or_default(),
            v["url"].as_str().unwrap_or_default(),
            self.clock.epoch
        ));
        let empty = Vec::new();
        for el in v["elements"].as_array().unwrap_or(&empty) {
            let mut line = format!(
                "[{}] {}",
                el["ref"].as_str().unwrap_or("?"),
                el["tag"].as_str().unwrap_or("?")
            );
            if let Some(t) = el["type"].as_str().filter(|t| !t.is_empty()) {
                line.push_str(&format!("[type={t}]"));
            }
            if let Some(r) = el["role"].as_str().filter(|r| !r.is_empty()) {
                line.push_str(&format!("[role={r}]"));
            }
            let name = el["name"].as_str().unwrap_or_default();
            if !name.is_empty() {
                line.push_str(&format!(" \"{name}\""));
            }
            if let Some(h) = el["href"].as_str().filter(|h| !h.is_empty()) {
                line.push_str(&format!(" -> {h}"));
            }
            if el["disabled"].as_bool().unwrap_or(false) {
                line.push_str(" (disabled)");
            }
            if el["checked"].as_bool().unwrap_or(false) {
                line.push_str(" (checked)");
            }
            if let Some(val) = el["value"].as_str().filter(|v| !v.is_empty()) {
                line.push_str(&format!(" value=\"{val}\""));
            }
            out.push_str(&line);
            out.push('\n');
        }
        if let Some(t) = v["text"].as_str().filter(|t| !t.is_empty()) {
            out.push_str("\nPage text:\n");
            out.push_str(t);
            out.push('\n');
        }
        out
    }

    async fn run(&mut self, action: &Action) -> Result<Vec<ToolContent>, String> {
        match action {
            Action::Navigate { url } => {
                super::action::validate_url(url)?;
                match tokio::time::timeout(NAV_TIMEOUT, self.page.goto(url.clone())).await {
                    Ok(Ok(_)) => {
                        let snap = self.snapshot_json().await?;
                        self.clock.stamp();
                        Ok(text(self.format_snapshot(&snap)))
                    }
                    Ok(Err(e)) => Err(format!("navigation failed: {e}")),
                    Err(_) => Err(format!("navigation to {url} timed out")),
                }
            }
            Action::Snapshot => {
                let snap = self.snapshot_json().await?;
                self.clock.stamp();
                Ok(text(self.format_snapshot(&snap)))
            }
            Action::Screenshot => {
                let png = tokio::time::timeout(
                    OP_TIMEOUT,
                    self.page.screenshot(
                        ScreenshotParams::builder()
                            .format(CaptureScreenshotFormat::Png)
                            .build(),
                    ),
                )
                .await
                .map_err(|_| "screenshot timed out".to_string())?
                .map_err(|e| format!("screenshot failed: {e}"))?;
                Ok(vec![
                    ToolContent::Text(page_header(&self.page, self.clock.epoch).await),
                    ToolContent::ImagePng(png),
                ])
            }
            Action::Click { target } => {
                self.element(target)
                    .await?
                    .click()
                    .await
                    .map_err(|e| format!("click failed: {e}"))?;
                Ok(text(format!(
                    "clicked {}\n{}",
                    target.to_css(),
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::Type {
                target,
                text: input,
                submit,
            } => {
                let el = self.element(target).await?;
                // JS focus, not a click: typing into a <button> must not
                // fire its click handler.
                el.focus()
                    .await
                    .map_err(|e| format!("could not focus element: {e}"))?;
                // Input.insertText types arbitrary Unicode in one shot;
                // press_key only covers the US key layout.
                tokio::time::timeout(
                    OP_TIMEOUT,
                    self.page.execute(
                        chromiumoxide::cdp::browser_protocol::input::InsertTextParams::new(
                            input.as_str(),
                        ),
                    ),
                )
                .await
                .map_err(|_| "typing timed out".to_string())?
                .map_err(|e| format!("typing failed: {e}"))?;
                if *submit {
                    el.press_key("Enter")
                        .await
                        .map_err(|e| format!("submit failed: {e}"))?;
                }
                Ok(text(format!(
                    "typed {} chars into {}\n{}",
                    input.chars().count(),
                    target.to_css(),
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::PressKey { key } => {
                let el = tokio::time::timeout(OP_TIMEOUT, self.page.find_element("body"))
                    .await
                    .map_err(|_| "key press timed out".to_string())?
                    .map_err(|e| format!("could not focus the page: {e}"))?;
                el.press_key(key.as_str())
                    .await
                    .map_err(|e| format!("unknown or unsupported key `{key}` ({e})"))?;
                Ok(text(format!(
                    "pressed {key}\n{}",
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::Scroll { direction, amount } => {
                let (dx, dy) = direction.delta(*amount);
                let pos: Value = self
                    .eval(&format!(
                        "(()=>{{window.scrollBy({dx},{dy});return {{x:scrollX,y:scrollY,top:scrollY<=0,bottom:scrollY+innerHeight>=document.documentElement.scrollHeight-1}}}})()"
                    ))
                    .await?;
                Ok(text(format!(
                    "scrolled {} {}px; scroll position ({}, {}){}{}\n{}",
                    match direction {
                        super::action::ScrollDirection::Up => "up",
                        super::action::ScrollDirection::Down => "down",
                        super::action::ScrollDirection::Left => "left",
                        super::action::ScrollDirection::Right => "right",
                    },
                    amount,
                    pos["x"].as_i64().unwrap_or_default(),
                    pos["y"].as_i64().unwrap_or_default(),
                    if pos["top"].as_bool() == Some(true) {
                        " (top of page)"
                    } else {
                        ""
                    },
                    if pos["bottom"].as_bool() == Some(true) {
                        " (bottom of page)"
                    } else {
                        ""
                    },
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::Back | Action::Forward | Action::Reload => {
                match action {
                    Action::Reload => {
                        tokio::time::timeout(NAV_TIMEOUT, self.page.reload())
                            .await
                            .map_err(|_| "reload timed out".to_string())?
                            .map_err(|e| format!("reload failed: {e}"))?;
                    }
                    _ => {
                        let js = if matches!(action, Action::Back) {
                            "history.back()"
                        } else {
                            "history.forward()"
                        };
                        // history.back() returns undefined, so only the
                        // transport-level result is meaningful here.
                        tokio::time::timeout(OP_TIMEOUT, self.page.evaluate(js))
                            .await
                            .map_err(|_| "history navigation timed out".to_string())?
                            .map_err(|e| format!("history navigation failed: {e}"))?;
                        tokio::time::sleep(Duration::from_millis(SETTLE_MS)).await;
                    }
                }
                Ok(text(format!(
                    "{}\n{}",
                    match action {
                        Action::Back => "went back",
                        Action::Forward => "went forward",
                        _ => "reloaded",
                    },
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::Wait { ms } => {
                tokio::time::sleep(Duration::from_millis(*ms)).await;
                Ok(text(format!("waited {ms}ms")))
            }
            Action::WaitFor {
                selector,
                timeout_ms,
            } => {
                let deadline = std::time::Instant::now() + Duration::from_millis(*timeout_ms);
                loop {
                    let found: bool = self
                        .eval(&format!(
                            "!!document.querySelector({})",
                            serde_json::to_string(selector).unwrap_or_default()
                        ))
                        .await
                        .unwrap_or(false);
                    if found {
                        return Ok(text(format!("`{selector}` appeared")));
                    }
                    if std::time::Instant::now() >= deadline {
                        return Err(format!("`{selector}` did not appear within {timeout_ms}ms"));
                    }
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
            Action::Evaluate { expression } => {
                let res: Value = self
                    .eval(&format!("(async()=>{{return ({expression})}})()"))
                    .await?;
                let mut s = serde_json::to_string_pretty(&res).unwrap_or_else(|_| res.to_string());
                if s.len() > MAX_EVAL_OUTPUT {
                    truncate_utf8(&mut s, MAX_EVAL_OUTPUT);
                    s.push_str("\n…[truncated]");
                }
                Ok(text(s))
            }
            Action::Select { target, values } => {
                let el = self.element(target).await?;
                let res = tokio::time::timeout(
                    OP_TIMEOUT,
                    el.call_js_fn(
                        format!(
                            "function() {{ \
                            if (this.tagName !== 'SELECT') return 'not a <select> element'; \
                            const wanted = {}; \
                            let matched = 0; \
                            for (const o of this.options) {{ \
                                o.selected = wanted.includes(o.value); \
                                if (o.selected) matched++; \
                            }} \
                            this.dispatchEvent(new Event('input', {{bubbles:true}})); \
                            this.dispatchEvent(new Event('change', {{bubbles:true}})); \
                            return matched === 0 ? 'no option matched the given values' : 'ok'; \
                        }}",
                            serde_json::to_string(values).unwrap_or_default()
                        ),
                        false,
                    ),
                )
                .await
                .map_err(|_| "select timed out".to_string())?
                .map_err(|e| format!("select failed: {e}"))?;
                let status = res
                    .result
                    .value
                    .and_then(|v| v.as_str().map(str::to_string))
                    .unwrap_or_else(|| "ok".into());
                if status != "ok" {
                    return Err(status);
                }
                Ok(text(format!(
                    "selected {} value(s) in {}\n{}",
                    values.len(),
                    target.to_css(),
                    page_header(&self.page, self.clock.epoch).await
                )))
            }
            Action::Hover { target } => {
                self.element(target)
                    .await?
                    .hover()
                    .await
                    .map_err(|e| format!("hover failed: {e}"))?;
                Ok(text(format!("hovered {}", target.to_css())))
            }
        }
    }
}

#[async_trait]
impl Engine for ChromiumEngine {
    async fn perform(&mut self, action: &Action) -> Result<Vec<ToolContent>, String> {
        if let Some(target) = action.target() {
            self.clock.check(target)?;
        }
        if action.invalidates_snapshot() {
            self.clock.bump();
        }
        self.run(action).await
    }

    fn alive(&mut self) -> bool {
        if self.handler.is_finished() {
            return false;
        }
        // chromiumoxide's handler never returns Ready(None) on a dead
        // connection, so the task handle alone cannot detect a crashed
        // browser; ask the child process directly.
        match self.browser.get_mut_child() {
            Some(child) => child
                .as_mut_inner()
                .try_wait()
                .map(|status| status.is_none())
                .unwrap_or(false),
            None => true,
        }
    }
}

impl Drop for ChromiumEngine {
    fn drop(&mut self) {
        self.handler.abort();
    }
}

#[cfg(unix)]
fn running_as_root() -> bool {
    rustix::process::geteuid().as_raw() == 0
}

#[cfg(not(unix))]
fn running_as_root() -> bool {
    false
}

/// In-page snapshot routine: tags interactive elements with `data-dvref`
/// and returns their accessible-ish description plus the body text.
const SNAPSHOT_JS: &str = r#"function(opts) {
    const ATTR = opts.attr;
    document.querySelectorAll('[' + ATTR + ']').forEach(e => e.removeAttribute(ATTR));
    const sel = 'a[href],button,input,textarea,select,summary,label,[role="button"],[role="link"],[role="checkbox"],[role="radio"],[role="textbox"],[role="combobox"],[role="listbox"],[role="option"],[role="tab"],[role="menuitem"],[role="switch"],[role="searchbox"],[role="slider"],[contenteditable="true"],[onclick],[tabindex]';
    const items = [];
    let n = 0;
    for (const el of document.querySelectorAll(sel)) {
        if (n >= opts.max) break;
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        if (cs.display === 'none' || cs.visibility === 'hidden' || r.width < 1 || r.height < 1) continue;
        const ref = String(++n);
        el.setAttribute(ATTR, ref);
        const name = (el.getAttribute('aria-label') || el.getAttribute('title') || el.innerText || el.value || el.placeholder || el.getAttribute('alt') || el.getAttribute('name') || '')
            .trim().replace(/\s+/g, ' ').slice(0, 120);
        items.push({
            ref,
            tag: el.tagName.toLowerCase(),
            type: el.getAttribute('type') || '',
            role: el.getAttribute('role') || '',
            name,
            href: el.getAttribute('href') || '',
            disabled: !!el.disabled,
            checked: el.checked === true,
            value: (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') ? String(el.value || '').slice(0, 100) : '',
        });
    }
    let text = document.body ? (document.body.innerText || '') : '';
    text = text.replace(/\n{3,}/g, '\n\n').trim();
    if (text.length > opts.textMax) text = text.slice(0, opts.textMax) + '\n...[truncated]';
    return { title: document.title, url: location.href, elements: items, text };
}"#;

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::sync::Mutex;

    /// Scripted engine for protocol tests: pops canned results, records the
    /// actions it was asked to run.
    pub struct FakeEngine {
        pub calls: Mutex<Vec<Action>>,
        pub results: Mutex<Vec<Result<Vec<ToolContent>, String>>>,
        pub alive: bool,
    }

    impl FakeEngine {
        pub fn new(results: Vec<Result<Vec<ToolContent>, String>>) -> Self {
            let mut results = results;
            results.reverse();
            Self {
                calls: Mutex::new(Vec::new()),
                results: Mutex::new(results),
                alive: true,
            }
        }
    }

    #[async_trait]
    impl Engine for FakeEngine {
        async fn perform(&mut self, action: &Action) -> Result<Vec<ToolContent>, String> {
            self.calls.lock().unwrap().push(action.clone());
            Ok(self
                .results
                .lock()
                .unwrap()
                .pop()
                .unwrap_or_else(|| Ok(text("ok")))?)
        }

        fn alive(&mut self) -> bool {
            self.alive
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ref_target(n: u64) -> Target {
        Target::Ref(n)
    }

    #[test]
    fn clock_check_ordering_matches_perform() {
        // perform() checks the target, then bumps, then runs. Simulate the
        // navigate -> snapshot -> click -> snapshot -> click flow.
        let mut clock = SnapshotClock::default();

        // No snapshot yet: ref tools fail, selector tools pass.
        assert!(clock.check(&ref_target(1)).is_err());
        assert!(clock.check(&Target::Selector("a".into())).is_ok());

        // browser_navigate bumps, then stamps a snapshot.
        clock.bump();
        clock.stamp();
        assert!(clock.check(&ref_target(3)).is_ok());

        // browser_click checks first (passes), then bumps.
        assert!(clock.check(&ref_target(3)).is_ok());
        clock.bump();
        assert!(clock.check(&ref_target(3)).is_err());

        // A fresh snapshot re-arms the refs.
        clock.stamp();
        assert!(clock.check(&ref_target(1)).is_ok());

        // Read-only actions never bump: scroll/snapshot leave refs valid.
        assert!(clock.check(&ref_target(2)).is_ok());
    }

    #[test]
    fn clock_selector_targets_bypass_staleness() {
        let clock = SnapshotClock::default();
        assert!(clock.check(&Target::Selector("div".into())).is_ok());
    }
}
