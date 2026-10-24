//! Rate-limit auto-retry for Devin CLI runs.
//!
//! When a Devin provider call fails with a rate-limit error, the run parks
//! itself for the advertised reset window: surfaced to clients as a
//! `rate_limit` event plus the `rate_limit` field on run snapshots, so the UI
//! can show a live countdown: then resumes the session with "continue
//! working". Non-Devin providers and non-rate-limit errors propagate
//! unchanged, and a user stop during the wait still aborts the run.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use chrono::{SecondsFormat, Utc};

use crate::db::{ThreadRow, UserRow};
use crate::providers::{AskCallback, PartCallback, PermissionCallback};
use crate::thread_runner::{RateLimitWait, RunState};
use crate::AppState;

use super::persistence::persist_user_message;
use super::send::{call_provider, ProviderOutcome, SendInput};
use super::MessageOut;

/// Call the provider, retrying rate-limit failures on Devin CLI threads.
///
/// Between attempts the run stays `Running` with a `RateLimitWait` on its
/// state; listeners get a `rate_limit` event (payload `null` when the wait
/// ends) so the countdown is visible live and on reconnect.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn call_provider_with_retry(
    state: &AppState,
    user: &UserRow,
    thread: &mut ThreadRow,
    input: &SendInput,
    permission_callback: Option<PermissionCallback>,
    ask_callback: Option<AskCallback>,
    part_callback: Option<PartCallback>,
    run: &Arc<RunState>,
) -> anyhow::Result<ProviderOutcome> {
    let mut attempt = 0u32;
    let mut retry_input: Option<SendInput> = None;
    loop {
        let call_input = retry_input.as_ref().unwrap_or(input);
        // `send` when a session id was already stored, `start` otherwise -
        // mirrored from `call_provider`'s own dispatch.
        let resuming = thread.devin_session_id.is_some();
        let result = call_provider(
            state,
            user,
            thread,
            call_input,
            permission_callback.clone(),
            ask_callback.clone(),
            part_callback.clone(),
            run.cancelled.clone(),
        )
        .await;

        let Err(e) = result else { return result };
        if run.cancelled.load(Ordering::SeqCst)
            || !crate::rate_limit::supports_auto_retry(&thread.provider_id)
        {
            return Err(e);
        }
        let Some(delay) = crate::rate_limit::retry_delay(&e.to_string(), Utc::now()) else {
            return Err(e);
        };
        attempt += 1;
        if attempt > crate::rate_limit::MAX_RETRIES {
            return Err(e);
        }

        let wait = RateLimitWait {
            retry_at: (Utc::now() + delay).to_rfc3339_opts(SecondsFormat::Millis, true),
            attempt,
            max_attempts: crate::rate_limit::MAX_RETRIES,
            message: e
                .to_string()
                .lines()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("rate limited")
                .trim()
                .chars()
                .take(200)
                .collect(),
        };
        let payload = serde_json::to_string(&wait).unwrap_or_else(|_| "{}".into());
        run.set_rate_limit(Some(wait));
        run.emit("rate_limit", &payload);
        wait_for_retry(delay, run.cancelled.clone()).await;
        run.set_rate_limit(None);
        run.emit("rate_limit", "null");

        if run.cancelled.load(Ordering::SeqCst) {
            return Err(e);
        }

        // The session callback can persist a session id even when the call
        // fails (session/new succeeded, session/prompt hit the limit), so
        // refresh before choosing how the retry goes out.
        if let Ok(Some(fresh)) = state.db.get_thread(&thread.id, user.id).await {
            if fresh.devin_session_id.is_some() {
                thread.devin_session_id = fresh.devin_session_id;
            }
        }
        let produced_output = !run
            .parts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty();

        retry_input = Some(
            if thread.devin_session_id.is_some() && (resuming || produced_output) {
                // The session already saw the user's prompt; a nudge resumes
                // it. Persisted as a real user message so the transcript is
                // honest about what the agent received.
                let cont = continue_input(input);
                let msg = persist_user_message(state, thread, &cont).await?;
                run.emit(
                    "user_message",
                    &serde_json::to_string(&MessageOut::from(msg)).unwrap_or_else(|_| "{}".into()),
                );
                cont
            } else {
                // The prompt never reached the model: no session, or a fresh
                // session that failed before its first prompt. Resend the
                // original input unchanged instead of a bare "continue
                // working" that would arrive without the task.
                input.clone()
            },
        );
    }
}

/// User-message body for the retry: "continue working" in the thread's
/// interaction mode, without re-attaching the original references.
fn continue_input(input: &SendInput) -> SendInput {
    SendInput {
        prompt: crate::rate_limit::RETRY_PROMPT.into(),
        mode: input.mode.clone(),
        attachments: Vec::new(),
        att_meta: Vec::new(),
        client_message_id: None,
        context_paths: Vec::new(),
        context_refs: Vec::new(),
        referenced_thread_ids: Vec::new(),
        thread_refs: Vec::new(),
        machine_ids: Vec::new(),
        machine_refs: Vec::new(),
        machine_token: None,
    }
}

/// Sleep until `delay` has passed or the run is cancelled, whichever comes
/// first. The cancel flag only flips from the stop endpoint, so polling it in
/// short slices ends the wait quickly without a dedicated notification
/// channel.
async fn wait_for_retry(
    delay: std::time::Duration,
    cancelled: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    let deadline = tokio::time::Instant::now() + delay;
    loop {
        if cancelled.load(Ordering::SeqCst) {
            return;
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return;
        }
        tokio::time::sleep(remaining.min(std::time::Duration::from_millis(200))).await;
    }
}

#[cfg(test)]
mod tests {
    use super::continue_input;
    use super::wait_for_retry;
    use crate::api::threads::send::SendInput;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    fn bare_input() -> SendInput {
        SendInput {
            prompt: "fix the bug".into(),
            mode: "plan".into(),
            attachments: vec![],
            att_meta: vec![],
            client_message_id: Some("cm-1".into()),
            context_paths: vec![],
            context_refs: vec![],
            referenced_thread_ids: vec![],
            thread_refs: vec![],
            machine_ids: vec![],
            machine_refs: vec![],
            machine_token: Some("tok".into()),
        }
    }

    #[test]
    fn continue_input_carries_mode_only() {
        let cont = continue_input(&bare_input());
        assert_eq!(cont.prompt, crate::rate_limit::RETRY_PROMPT);
        assert_eq!(cont.mode, "plan");
        assert!(cont.attachments.is_empty());
        assert!(cont.context_refs.is_empty());
        assert!(cont.thread_refs.is_empty());
        assert!(cont.machine_refs.is_empty());
        assert!(cont.machine_token.is_none());
        assert!(cont.client_message_id.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn wait_for_retry_ends_on_deadline() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let start = tokio::time::Instant::now();
        wait_for_retry(Duration::from_secs(30), cancelled).await;
        assert_eq!(start.elapsed(), Duration::from_secs(30));
    }

    #[tokio::test(start_paused = true)]
    async fn wait_for_retry_ends_on_cancel() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let handle = tokio::spawn(wait_for_retry(Duration::from_secs(3600), cancelled.clone()));
        tokio::time::sleep(Duration::from_millis(500)).await;
        cancelled.store(true, Ordering::SeqCst);
        tokio::time::timeout(Duration::from_secs(10), handle)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn wait_for_retry_returns_immediately_when_zero() {
        let cancelled = Arc::new(AtomicBool::new(false));
        tokio::time::timeout(
            Duration::from_secs(1),
            wait_for_retry(Duration::ZERO, cancelled),
        )
        .await
        .unwrap();
    }
}
