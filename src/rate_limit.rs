//! Rate-limit detection and retry-delay parsing for provider errors.
//!
//! Only Devin CLI (`devin-cli`) threads auto-retry: its free-tier errors carry
//! an explicit reset hint ("Your limit will reset in 15 seconds (at 18:04
//! UTC)") plus a `"cognition.ai/retryable": true` marker, and its ACP sessions
//! survive a rejected prompt so a follow-up nudge resumes the turn. Every
//! other provider keeps failing the run immediately.

use std::sync::LazyLock;
use std::time::Duration;

use chrono::{DateTime, Utc};
use regex::Regex;

/// Total number of rate-limit retries a single run will attempt before the
/// error is surfaced like any other provider failure.
pub const MAX_RETRIES: u32 = 8;

/// The message sent to the agent once the reported wait has elapsed. It shows
/// up in the thread as a normal user message so the transcript stays honest
/// about what the agent was told.
pub const RETRY_PROMPT: &str = "continue working";

/// Even a "reset in 0 seconds" hint gets a beat so the retry cannot spin in a
/// tight loop when the provider keeps misreporting an instant reset.
const MIN_DELAY: Duration = Duration::from_secs(1);

/// A reset hint far in the future (a daily quota, say) is retried sooner than
/// advertised so a stale message cannot park the run for hours; the next
/// failure carries a fresh, usually shorter, hint.
const MAX_DELAY: Duration = Duration::from_secs(30 * 60);

/// Used when the error is recognizably a rate limit but carries no usable
/// reset time.
const DEFAULT_DELAY: Duration = Duration::from_secs(30);

/// "reset in 15 seconds", "retry in 1 minute", "try again in 2h", "available
/// in a minute".
static RELATIVE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:reset|resets|retry|retrying|retries|try|wait|available|throttled|cooldown|cool\s*down)\w*\s+(?:again\s+)?in\s+(a|an|\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b",
    )
    .unwrap()
});

/// "(at 18:04 UTC)" / "at 18:04:30 UTC": Devin pairs the relative hint with
/// the wall-clock reset time.
static ABSOLUTE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bat\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*UTC\b").unwrap());

/// Whether the provider wired to the thread is one we know how to auto-retry.
/// Only Devin CLI reports a parseable reset hint and marks the failure
/// retryable; Codex, OpenCode, and Grok errors keep their old behavior.
pub fn supports_auto_retry(provider_id: &str) -> bool {
    provider_id == crate::providers::acp::AgentKind::Devin.id()
}

/// Whether the error text looks like a rate limit rather than a generic
/// failure. A bare `"retryable": true` marker counts too: Devin only emits
/// it on errors it wants the client to re-run.
pub fn is_rate_limit_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    if lower.contains("rate limit")
        || lower.contains("rate_limit")
        || lower.contains("ratelimit")
        || lower.contains("too many requests")
        || lower.contains("resource_exhausted")
        || lower.contains("resource exhausted")
        || lower.contains("quota exceeded")
    {
        return true;
    }
    let squashed: String = lower.split_whitespace().collect();
    // The key arrives namespaced ("cognition.ai/retryable"), so match on the
    // `":true` tail instead of an anchored key name.
    squashed.contains("retryable\":true")
}

/// How long to wait before retrying the failed provider call, or `None` when
/// the error is not a rate limit. The delay comes from the explicit "reset in
/// N <unit>" hint first, then the "(at HH:MM UTC)" wall-clock time, then a
/// conservative default, clamped into `[MIN_DELAY, MAX_DELAY]`.
pub fn retry_delay(error: &str, now: DateTime<Utc>) -> Option<Duration> {
    if !is_rate_limit_error(error) {
        return None;
    }
    let delay = relative_delay(error)
        .or_else(|| absolute_delay(error, now))
        .unwrap_or(DEFAULT_DELAY);
    Some(delay.clamp(MIN_DELAY, MAX_DELAY))
}

fn relative_delay(error: &str) -> Option<Duration> {
    let caps = RELATIVE_RE.captures(error)?;
    let amount: f64 = match caps.get(1)?.as_str().to_lowercase().as_str() {
        "a" | "an" => 1.0,
        s => s.parse().ok()?,
    };
    let unit = caps.get(2)?.as_str().to_lowercase();
    let secs = match unit.as_str() {
        "s" | "sec" | "secs" | "second" | "seconds" => amount,
        "m" | "min" | "mins" | "minute" | "minutes" => amount * 60.0,
        _ => amount * 3600.0,
    };
    if !secs.is_finite() || secs < 0.0 {
        return None;
    }
    Some(Duration::from_secs_f64(secs))
}

fn absolute_delay(error: &str, now: DateTime<Utc>) -> Option<Duration> {
    let caps = ABSOLUTE_RE.captures(error)?;
    let hour: u32 = caps.get(1)?.as_str().parse().ok()?;
    let minute: u32 = caps.get(2)?.as_str().parse().ok()?;
    let second: u32 = caps
        .get(3)
        .and_then(|m| m.as_str().parse().ok())
        .unwrap_or(0);
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let today = now.date_naive();
    let target = today.and_hms_opt(hour, minute, second)?.and_utc();
    let diff = (target - now).to_std().ok();
    // A reset time that just passed means the window already opened; retry
    // right away rather than waiting a full day for the next occurrence.
    Some(diff.unwrap_or(MIN_DELAY))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(h: u32, m: u32, s: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 24, h, m, s).unwrap()
    }

    #[test]
    fn parses_devin_free_tier_message() {
        let e = "acp connection failed: Reached free model rate limit. Upgrade \
                 to Max for higher limits, or switch to a different model. Your \
                 limit will reset in 15 seconds (at 18:04 UTC).: {\n\
                 \"cognition.ai/errorKind\": \"unavailable\",\n\
                 \"cognition.ai/retryable\": true\n}";
        assert_eq!(retry_delay(e, at(18, 3, 45)), Some(Duration::from_secs(15)));
    }

    #[test]
    fn relative_hint_wins_over_absolute() {
        // Both present: the relative hint is authoritative even when the wall
        // clock disagrees.
        let e = "rate limit, reset in 2 minutes (at 10:00 UTC)";
        assert_eq!(retry_delay(e, at(9, 0, 0)), Some(Duration::from_secs(120)));
    }

    #[test]
    fn parses_absolute_reset_time() {
        let e = "rate limit reached, resets at 18:04 UTC";
        assert_eq!(retry_delay(e, at(18, 3, 45)), Some(Duration::from_secs(15)));
    }

    #[test]
    fn parses_absolute_reset_time_with_seconds() {
        let e = "rate limit reached, resets at 18:04:30 UTC";
        assert_eq!(retry_delay(e, at(18, 4, 0)), Some(Duration::from_secs(30)));
    }

    #[test]
    fn absolute_time_just_passed_retries_immediately() {
        let e = "rate limit reached, resets at 18:04 UTC";
        assert_eq!(retry_delay(e, at(18, 4, 30)), Some(MIN_DELAY));
    }

    #[test]
    fn absolute_time_in_the_past_means_the_window_already_opened() {
        // A reset timestamp hours behind "now" already happened: the limit
        // lifted, so retry right away instead of waiting for tomorrow.
        let e = "rate limit reached, resets at 09:00 UTC";
        assert_eq!(retry_delay(e, at(18, 0, 0)), Some(MIN_DELAY));
    }

    #[test]
    fn parses_minutes_hours_and_shorthand() {
        for (text, secs) in [
            ("rate limit, reset in 1 minute", 60),
            ("rate limit, reset in 2 minutes", 120),
            // Hour-scale hints clamp to MAX_DELAY.
            ("rate limit, retry in 1 hour", MAX_DELAY.as_secs()),
            ("rate limit, try again in 3h", MAX_DELAY.as_secs()),
            ("rate limit, available in 45s", 45),
            ("rate limit, reset in a minute", 60),
            ("rate limit, reset in an hour", MAX_DELAY.as_secs()),
            ("rate limit, reset in 1.5 minutes", 90),
        ] {
            let d = retry_delay(text, at(0, 0, 0));
            assert_eq!(d, Some(Duration::from_secs(secs)), "{text}");
        }
        // "500 ms" must not parse as 500 minutes/seconds; falls back to the
        // default delay instead.
        assert_eq!(
            retry_delay("rate limit, try again in 500 ms", at(0, 0, 0)),
            Some(DEFAULT_DELAY)
        );
    }

    #[test]
    fn clamps_zero_and_huge_delays() {
        assert_eq!(
            retry_delay("rate limit, reset in 0 seconds", at(0, 0, 0)),
            Some(MIN_DELAY)
        );
        assert_eq!(
            retry_delay("rate limit, reset in 99 hours", at(0, 0, 0)),
            Some(MAX_DELAY)
        );
    }

    #[test]
    fn default_delay_when_no_hint() {
        assert_eq!(
            retry_delay("Too many requests", at(0, 0, 0)),
            Some(DEFAULT_DELAY)
        );
        assert_eq!(
            retry_delay(
                "acp connection failed: boom: {\"cognition.ai/retryable\": true}",
                at(0, 0, 0)
            ),
            Some(DEFAULT_DELAY)
        );
    }

    #[test]
    fn non_rate_limit_errors_do_not_retry() {
        for e in [
            "acp connection failed: stream closed",
            "session/new failed: unauthorized",
            "process exited with status 1",
            "stopped by user",
        ] {
            assert_eq!(retry_delay(e, at(0, 0, 0)), None, "{e}");
        }
    }

    #[test]
    fn case_insensitive_matching() {
        assert!(is_rate_limit_error("RATE LIMIT exceeded"));
        assert!(is_rate_limit_error("Rate_Limit hit"));
        assert!(!is_rate_limit_error("limited rate of progress"));
    }

    #[test]
    fn only_devin_supports_auto_retry() {
        assert!(supports_auto_retry("devin-cli"));
        assert!(!supports_auto_retry("opencode"));
        assert!(!supports_auto_retry("codex-cli"));
        assert!(!supports_auto_retry("grok"));
        assert!(!supports_auto_retry(""));
    }

    #[test]
    fn parses_utc_case_insensitively() {
        let e = "rate limit reached, resets at 18:04 utc";
        assert_eq!(retry_delay(e, at(18, 3, 45)), Some(Duration::from_secs(15)));
    }
}
