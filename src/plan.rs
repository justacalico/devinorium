//! Plan / todo parsing for AI turns.
//!
//! Devinorium does not have a provider-native TodoWrite tool, so we ask the
//! model to emit structured plan blocks in its output and parse them here.
//!
//! Supported formats:
//!   - `<proposed_plan explanation="...">` for the initial plan in Plan mode.
//!   - `<update_plan explanation="...">` for progress updates in Code mode.
//!   - Markdown checkboxes as a lightweight fallback.

use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

/// Status of a single plan step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStepStatus {
    Pending,
    InProgress,
    Completed,
}

impl PlanStepStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            PlanStepStatus::Pending => "pending",
            PlanStepStatus::InProgress => "in_progress",
            PlanStepStatus::Completed => "completed",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s.trim().to_lowercase().as_str() {
            "in_progress" | "inprogress" | "in-progress" | "active" | "[-]" | "[/]" => {
                PlanStepStatus::InProgress
            }
            "completed" | "done" | "complete" | "[x]" | "[X]" => PlanStepStatus::Completed,
            _ => PlanStepStatus::Pending,
        }
    }
}

impl std::fmt::Display for PlanStepStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// A single step in a plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub step: String,
    pub status: PlanStepStatus,
}

impl PlanStep {
    pub fn new(step: impl Into<String>, status: PlanStepStatus) -> Self {
        Self {
            step: step.into().trim().to_string(),
            status,
        }
    }
}

/// An active plan: an optional high-level explanation and an ordered list of
/// steps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    pub explanation: Option<String>,
    pub steps: Vec<PlanStep>,
}

impl Plan {
    pub fn new(explanation: Option<String>, steps: Vec<PlanStep>) -> Self {
        Self {
            explanation: explanation.filter(|s| !s.trim().is_empty()),
            steps,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }

    /// Percentage of steps that are completed (0-100).
    pub fn progress_percent(&self) -> u8 {
        if self.steps.is_empty() {
            return 0;
        }
        let completed = self
            .steps
            .iter()
            .filter(|s| s.status == PlanStepStatus::Completed)
            .count();
        let percent = ((completed as f64 / self.steps.len() as f64) * 100.0).round() as u8;
        percent.clamp(0, 100)
    }
}

/// Stateful parser that scans a stream of assistant text for complete plan
/// blocks and returns each parsed plan in the order it is detected.
///
/// Call [`feed`] with each new text chunk. Once a complete block has been seen,
/// the parser returns the corresponding [`Plan`] and removes the consumed text
/// from its internal buffer.
#[derive(Debug)]
pub struct PlanParser {
    buffer: String,
    proposed_re: Regex,
    update_re: Regex,
    checkbox_re: Regex,
    #[cfg(test)]
    panic_next_feed: bool,
}

impl PlanParser {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
            proposed_re: Regex::new(
                r#"(?s)<proposed_plan(?:\s+explanation="([^"]*)")?\s*>(.*?)</proposed_plan>"#
            )
            .expect("valid proposed_plan regex"),
            update_re: Regex::new(
                r#"(?s)<update_plan(?:\s+explanation="([^"]*)")?\s*>(.*?)</update_plan>"#
            )
            .expect("valid update_plan regex"),
            checkbox_re: Regex::new(
                r"(?m)^\s*[-*]\s*\[(\s|x|X|/|-)\]\s*(.+)$"
            )
            .expect("valid checkbox regex"),
            #[cfg(test)]
            panic_next_feed: false,
        }
    }

    /// Append new text and return any complete plan blocks found.
    pub fn feed(&mut self, text: &str) -> Vec<Plan> {
        #[cfg(test)]
        if std::mem::replace(&mut self.panic_next_feed, false) {
            panic!("forced plan parser panic for feed_safe test");
        }
        self.buffer.push_str(text);
        let mut plans = Vec::new();
        plans.extend(self.drain_blocks(&self.proposed_re.clone()));
        plans.extend(self.drain_blocks(&self.update_re.clone()));

        // Only fall back to markdown checkboxes if no explicit XML plan has
        // been seen in this turn yet and the buffer looks like a checklist.
        if plans.is_empty() && self.checkbox_re.is_match(&self.buffer) {
            if let Some(plan) = self.drain_checkboxes() {
                plans.push(plan);
            }
        }

        // Keep the buffer from growing unboundedly. We retain at most the last
        // 64 KiB so a split block that spans chunks can still be reassembled.
        self.trim_buffer();
        plans
    }

    fn drain_blocks(&mut self, re: &Regex) -> Vec<Plan> {
        let mut plans = Vec::new();
        let mut last_end = 0;
        let text = self.buffer.clone();
        let mut next_buffer = String::with_capacity(text.len());

        for caps in re.captures_iter(&text) {
            let full_match = caps.get(0).expect("capture 0 exists");
            let explanation = caps.get(1).map(|m| unescape_html(m.as_str()));
            let steps_text = caps.get(2).map(|m| m.as_str()).unwrap_or("");

            if let Some(plan) = parse_steps_text(steps_text, explanation) {
                plans.push(plan);
            }

            // Keep the unmatched text between this match and the previous one
            // so partial blocks that span chunks can still be reassembled.
            next_buffer.push_str(&text[last_end..full_match.start()]);
            last_end = full_match.end();
        }

        if last_end > 0 {
            next_buffer.push_str(&text[last_end..]);
            self.buffer = next_buffer;
        }

        plans
    }

    fn drain_checkboxes(&mut self) -> Option<Plan> {
        let mut steps = Vec::new();
        let mut kept = String::with_capacity(self.buffer.len());
        for line in self.buffer.lines() {
            if let Some(caps) = self.checkbox_re.captures(line) {
                let marker = caps.get(1)?.as_str();
                let step = caps.get(2)?.as_str().trim();
                if step.is_empty() {
                    continue;
                }
                let status = PlanStepStatus::from_str(&format!("[{marker}]"));
                steps.push(PlanStep::new(
                    truncate(step, MAX_STEP_LEN).into_owned(),
                    status,
                ));
            } else {
                if !kept.is_empty() {
                    kept.push('\n');
                }
                kept.push_str(line);
            }
        }
        if steps.is_empty() {
            None
        } else {
            steps.truncate(MAX_STEPS);
            self.buffer = kept;
            Some(Plan::new(None, steps))
        }
    }

    fn trim_buffer(&mut self) {
        const MAX_KEEP: usize = 64 * 1024;
        if self.buffer.len() <= MAX_KEEP {
            return;
        }

        let mut start = self.buffer.len() - MAX_KEEP;

        // Do not split a multi-byte UTF-8 character. If the byte cut point
        // falls inside a character, move it back to the character's start so
        // the kept suffix stays valid UTF-8.
        while start > 0 && !self.buffer.is_char_boundary(start) {
            start -= 1;
        }

        // Avoid cutting inside an XML-like tag. If the cut point is inside a
        // tag, move the start to the tag's opening '<' so the parser can still
        // reassemble the block as more chunks arrive.
        if let Some(relative_lt) = self.buffer[..start].rfind('<') {
            if self.buffer[relative_lt..start].find('>').is_none() {
                let tag_start = relative_lt;
                if self.buffer.len() - tag_start <= 2 * MAX_KEEP {
                    start = tag_start;
                }
            }
        }

        self.buffer = self.buffer[start..].to_string();
    }
}

impl Default for PlanParser {
    fn default() -> Self {
        Self::new()
    }
}

static NUMERIC_ENTITY_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"&#(x?[0-9a-fA-F]+);").expect("valid entity regex"));

fn unescape_html(s: &str) -> String {
    let out = s
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">");

    // Decode decimal and hexadecimal numeric entities.
    let mut result = String::with_capacity(out.len());
    let mut last = 0;
    for caps in NUMERIC_ENTITY_RE.captures_iter(&out) {
        let m = caps.get(0).expect("full match exists");
        let raw = caps.get(1).expect("group exists").as_str();
        let codepoint = if raw.starts_with('x') || raw.starts_with('X') {
            u32::from_str_radix(&raw[1..], 16)
        } else {
            raw.parse()
        };
        result.push_str(&out[last..m.start()]);
        last = m.end();
        match codepoint.ok().and_then(char::from_u32) {
            Some(c) => result.push(c),
            None => result.push_str(m.as_str()),
        }
    }
    result.push_str(&out[last..]);
    result
}

const MAX_EXPLANATION_LEN: usize = 2000;
const MAX_STEP_LEN: usize = 500;
const MAX_STEPS: usize = 100;

static STEP_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?s)<step(?:\s+status="([^"]*)")?\s*>(.*?)</step>"#)
        .expect("valid step regex")
});

fn parse_steps_text(text: &str, explanation: Option<String>) -> Option<Plan> {
    let mut steps = Vec::new();

    // Try XML <step> children first.
    for caps in STEP_RE.captures_iter(text) {
        let status = caps
            .get(1)
            .map(|m| PlanStepStatus::from_str(m.as_str()))
            .unwrap_or(PlanStepStatus::Pending);
        let step = caps.get(2).map(|m| m.as_str().trim()).unwrap_or("");
        if !step.is_empty() {
            steps.push(PlanStep::new(unescape_html(step), status));
        }
    }

    // If no <step> tags were found, fall back to one step per non-empty line.
    if steps.is_empty() {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            // Trim a leading checkbox if the model used one inside the block.
            let step = trim_checkbox(line);
            steps.push(PlanStep::new(step, PlanStepStatus::Pending));
        }
    }

    if steps.is_empty() {
        None
    } else {
        let explanation = explanation.map(|e| truncate(&e, MAX_EXPLANATION_LEN).into_owned());
        steps.truncate(MAX_STEPS);
        for step in steps.iter_mut() {
            step.step = truncate(&step.step, MAX_STEP_LEN).into_owned();
        }
        Some(Plan::new(explanation, steps))
    }
}

fn truncate(s: &str, max: usize) -> std::borrow::Cow<'_, str> {
    if s.len() <= max {
        std::borrow::Cow::Borrowed(s)
    } else {
        let mut end = max;
        while end > 0 && !s.is_char_boundary(end) {
            end -= 1;
        }
        std::borrow::Cow::Owned(s[..end].to_string())
    }
}

fn payload_as_string(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}

fn trim_checkbox(line: &str) -> String {
    let line = line.trim();
    if let Some(pos) = line.find(']') {
        let prefix = &line[..=pos];
        if prefix.starts_with('[') && prefix.len() <= 4 {
            return line[pos + 1..].trim().to_string();
        }
    }
    line.to_string()
}

/// Plan detector that wraps a [`PlanParser`] and folds multiple updates into
/// one active plan. A `proposed_plan` or `update_plan` fully replaces the
/// current plan, so the model can re-emit the whole list with new statuses.
#[derive(Debug, Default)]
pub struct PlanAccumulator {
    parser: PlanParser,
    current: Option<Plan>,
}

impl PlanAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a text chunk and return `true` if the active plan changed.
    pub fn feed(&mut self, text: &str) -> bool {
        let mut changed = false;
        for plan in self.parser.feed(text) {
            self.current = Some(plan);
            changed = true;
        }
        changed
    }

    /// Like [`feed`](Self::feed) but never panics. Plan parsing runs on a
    /// tokio worker thread where an unexpected panic would take the whole
    /// backend down. Any character the model emits must not be able to crash
    /// the server, so we catch unwinds here, log them, and leave the previous
    /// plan untouched. The text chunk itself is still saved as a message part
    /// by the caller regardless of this return value.
    pub fn feed_safe(&mut self, text: &str) -> bool {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.feed(text))) {
            Ok(changed) => changed,
            Err(payload) => {
                tracing::warn!(
                    payload = %payload_as_string(&payload),
                    "plan parser panicked on model text; skipping plan update"
                );
                false
            }
        }
    }

    pub fn current(&self) -> Option<&Plan> {
        self.current.as_ref()
    }

    pub fn take(&mut self) -> Option<Plan> {
        self.current.take()
    }

    /// Apply an explicit plan (e.g. from a persisted message on load).
    pub fn set(&mut self, plan: Plan) {
        self.current = Some(plan);
    }

    #[cfg(test)]
    fn force_parser_panic(&mut self) {
        self.parser.panic_next_feed = true;
    }
}

/// Build the prompt prefix/suffix that tells the model how to emit plans.
pub fn plan_mode_prompt(prompt: &str) -> String {
    format!(
        "You are in Plan mode. Produce a concise, decision-complete plan and do \
not run tools, edit files, or execute commands until the user confirms. \
When you present the plan, wrap it in a `<proposed_plan>` block with \
`<step status=\"pending\">...</step>` children. At most one step may be \
`in_progress`.\n\n{prompt}"
    )
}

pub fn code_mode_plan_hint() -> &'static str {
    "When working on a multi-step task, you may track progress by emitting \
`<update_plan explanation=\"...\"><step status=\"pending|in_progress|completed\">...\
</step></update_plan>` blocks. Only one step should be `in_progress` at a time."
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_proposed_plan() {
        let text = r#"<proposed_plan explanation="Build the feature">
<step status="pending">Add migration</step>
<step status="pending">Wire API</step>
<step status="pending">Build UI</step>
</proposed_plan>"#;
        let mut parser = PlanParser::new();
        let plans = parser.feed(text);
        assert_eq!(plans.len(), 1);
        let plan = &plans[0];
        assert_eq!(plan.explanation.as_deref(), Some("Build the feature"));
        assert_eq!(plan.steps.len(), 3);
        assert_eq!(plan.steps[0].step, "Add migration");
        assert_eq!(plan.steps[0].status, PlanStepStatus::Pending);
    }

    #[test]
    fn parse_update_plan_replaces_status() {
        let text = r#"<update_plan explanation="Build the feature">
<step status="completed">Add migration</step>
<step status="in_progress">Wire API</step>
<step status="pending">Build UI</step>
</update_plan>"#;
        let mut parser = PlanParser::new();
        let plans = parser.feed(text);
        assert_eq!(plans[0].steps[0].status, PlanStepStatus::Completed);
        assert_eq!(plans[0].steps[1].status, PlanStepStatus::InProgress);
        assert_eq!(plans[0].steps[2].status, PlanStepStatus::Pending);
    }

    #[test]
    fn parse_markdown_checkboxes() {
        let text = "- [ ] Add migration\n- [x] Wire API\n- [-] Build UI";
        let mut parser = PlanParser::new();
        let plans = parser.feed(text);
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].steps[0].status, PlanStepStatus::Pending);
        assert_eq!(plans[0].steps[1].status, PlanStepStatus::Completed);
        assert_eq!(plans[0].steps[2].status, PlanStepStatus::InProgress);
    }

    #[test]
    fn accumulate_plans() {
        let mut acc = PlanAccumulator::new();
        assert!(acc.feed(
            r#"<proposed_plan><step status="pending">A</step><step status="pending">B</step></proposed_plan>"#
        ));
        assert!(acc.feed(r#"<update_plan><step status="completed">A</step><step status="in_progress">B</step></update_plan>"#));
        let plan = acc.current().unwrap();
        assert_eq!(plan.steps[0].status, PlanStepStatus::Completed);
        assert_eq!(plan.steps[1].status, PlanStepStatus::InProgress);
    }

    #[test]
    fn split_block_across_chunks() {
        let mut parser = PlanParser::new();
        assert!(parser.feed("<proposed_plan><step status=\"pending\">").is_empty());
        let plans = parser.feed("Add migration</step></proposed_plan>");
        assert_eq!(plans.len(), 1);
        assert_eq!(plans[0].steps[0].step, "Add migration");
    }

    #[test]
    fn progress_percent() {
        let plan = Plan::new(
            None,
            vec![
                PlanStep::new("A", PlanStepStatus::Completed),
                PlanStep::new("B", PlanStepStatus::Completed),
                PlanStep::new("C", PlanStepStatus::Pending),
            ],
        );
        assert_eq!(plan.progress_percent(), 67);
    }

    #[test]
    fn trim_does_not_split_multibyte_char() {
        let mut parser = PlanParser::new();

        // Build a buffer where the 64 KiB byte cut point falls inside a
        // multi-byte UTF-8 character (U+53D1, 3 bytes). This used to panic
        // when trim_buffer sliced the string at a non-char-boundary.
        let prefix = "x".repeat(10);
        let suffix = "x".repeat(65534);
        let mut text = String::with_capacity(65547);
        text.push_str(&prefix);
        text.push('发');
        text.push_str(&suffix);

        let plans = parser.feed(&text);
        assert!(plans.is_empty());
        assert!(parser.buffer.contains('发'));
        assert!(parser.buffer.len() > 64 * 1024);
        assert!(parser.buffer.len() <= 64 * 1024 + 3);
    }

    #[test]
    fn feed_safe_matches_feed_on_normal_input() {
        let text = r#"<proposed_plan explanation="Build it">
<step status="pending">A</step>
<step status="in_progress">B</step>
</proposed_plan>"#;
        let mut a = PlanAccumulator::new();
        let mut b = PlanAccumulator::new();
        assert_eq!(a.feed_safe(text), b.feed(text));
        assert_eq!(a.current(), b.current());
    }

    #[test]
    fn feed_safe_swallows_parser_panic() {
        let mut acc = PlanAccumulator::new();
        // Seed an existing plan so we can confirm it survives the panic.
        assert!(acc.feed_safe(
            r#"<proposed_plan><step status="pending">A</step></proposed_plan>"#
        ));
        let before = acc.current().cloned();

        acc.force_parser_panic();
        // feed_safe must not propagate the panic.
        assert!(!acc.feed_safe("anything"));
        // The prior plan is untouched.
        assert_eq!(acc.current(), before.as_ref());

        // The accumulator is still usable after the caught panic.
        assert!(acc.feed_safe(
            r#"<update_plan><step status="completed">A</step></update_plan>"#
        ));
        let plan = acc.current().expect("plan updated after recovery");
        assert_eq!(plan.steps[0].status, PlanStepStatus::Completed);
    }

    #[test]
    fn feed_safe_handles_multibyte_trim_edge_case() {
        // The em-dash scenario from the original crash report: a 3-byte
        // character sitting right at the 64 KiB trim cut point. feed_safe
        // must not panic and the accumulator must keep working.
        let mut acc = PlanAccumulator::new();
        let mut text = String::with_capacity(65547);
        text.push_str(&"x".repeat(10));
        text.push('—');
        text.push_str(&"x".repeat(65534));
        assert!(!acc.feed_safe(&text));
        assert!(acc
            .feed_safe(r#"<update_plan><step status="completed">A</step></update_plan>"#));
    }
}
