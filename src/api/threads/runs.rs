//! Run lifecycle: status, stop, events, and the background provider runner.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures::stream::{BoxStream, StreamExt as FuturesStreamExt};
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt as TokioStreamExt;

use crate::api::map_err_internal;
use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::db::{MessageRow, NewMessage, ThreadRow, UserRow};
use crate::plan::PlanAccumulator;
use crate::providers::{
    collect_text, collect_thinking, strip_plan_markup_from_parts, MessagePart, PartCallback,
    PartEvent,
};
use crate::thread_runner::{RunState, RunStatus};
use crate::AppState;

use super::permissions::{build_ask_callback, build_permission_callback};
use super::persistence::{
    persist_assistant_reply, persist_run_plan, save_partial_assistant_message,
    update_thread_title_from_send,
};
use super::send::{call_provider, ProviderOutcome, SendInput};
use super::worktree::{snapshot_worktree_paths, sync_agent_created_worktree};
use super::MessageOut;

/// Get the current run status for a thread. Returns the active or most recent
/// run, or `{"status":"idle"}` if the thread has no run in memory.
pub(super) async fn get_run(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    }

    match state.thread_runner.get(&id).await {
        Some(run) => Json(run.snapshot().await).into_response(),
        None => Json(serde_json::json!({
            "run_id": null,
            "thread_id": id,
            "status": RunStatus::Idle.to_string(),
            "started_at": null,
            "updated_at": null,
            "error": null,
            "text": "",
            "thinking": "",
            "thinking_active": false,
            "parts": [],
            "tool_calls": [],
            "permission_request": null,
            "ask_request": null,
            "last_seq": 0,
        }))
        .into_response(),
    }
}

/// Return the ids of all currently running threads for the caller.
/// This avoids the N+1 cost of polling `/api/threads/:id/run` for every thread.
pub(super) async fn list_runs(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    let running = state.thread_runner.running_ids().await;
    match state.db.filter_user_thread_ids(user.id, &running).await {
        Ok(ids) => Json(serde_json::json!({"running_ids": ids })).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Stop the currently running model/ACP session for a thread.
pub(super) async fn stop(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    }

    match state.thread_runner.stop(&id).await {
        Some(snapshot) => Json(snapshot).into_response(),
        None => (StatusCode::NOT_FOUND, Json(ApiError::new("no active run"))).into_response(),
    }
}

/// Subscribe to the events of the current run as an SSE stream. Reconnecting
/// clients can resume watching a long-running thread without sending a new
/// message.
pub(super) async fn events(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    match state.db.get_thread(&id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    }

    match state.thread_runner.get(&id).await {
        Some(run) => events_stream(run).await.into_response(),
        None => (StatusCode::NOT_FOUND, Json(ApiError::new("no active run"))).into_response(),
    }
}

pub(crate) async fn events_stream(
    run: Arc<RunState>,
) -> Sse<BoxStream<'static, Result<Event, std::convert::Infallible>>> {
    // Subscribe first so events emitted while the snapshot is being built are
    // captured in the live stream and not lost.
    let live: BoxStream<'static, Result<Event, std::convert::Infallible>> = match run.subscribe() {
        Some(receiver) => FuturesStreamExt::boxed(TokioStreamExt::filter_map(
            BroadcastStream::new(receiver),
            |res| match res {
                Ok(ev) => {
                    let data = if ev.event == "error" {
                        super::send::sanitize_sse_data(&ev.data)
                    } else {
                        ev.data
                    };
                    Some(Ok::<_, std::convert::Infallible>(
                        Event::default()
                            .event(&ev.event)
                            .id(ev.seq.to_string())
                            .data(data),
                    ))
                }
                Err(_) => None,
            },
        )),
        None => FuturesStreamExt::boxed(tokio_stream::empty()),
    };

    let snapshot = run.snapshot().await;
    let state_json = serde_json::to_string(&snapshot).unwrap_or_else(|_| "{}".to_string());
    let state_event =
        Ok::<_, std::convert::Infallible>(Event::default().event("state").data(state_json));
    let initial = tokio_stream::once(state_event);

    Sse::new(FuturesStreamExt::boxed(FuturesStreamExt::chain(
        initial, live,
    )))
}

pub(crate) async fn run_thread(
    state: AppState,
    run: Arc<RunState>,
    user: UserRow,
    mut thread: ThreadRow,
    input: SendInput,
    user_msg: MessageRow,
) -> anyhow::Result<()> {
    match update_thread_title_from_send(&state, user.id, &mut thread, &input).await {
        Ok(true) => {
            if let Ok(json) = serde_json::to_string(&serde_json::json!({
                "title": thread.title,
                "updated_at": thread.updated_at,
            })) {
                run.emit("thread_update", &json);
            }
        }
        Ok(false) => {}
        Err(e) => {
            tracing::error!(error = %e, "failed to update thread title from send");
        }
    }

    // Sync the thread's git/worktree metadata so the toolbar reflects the
    // actual worktree the agent runs in. Without this the UI keeps showing the
    // main worktree when one was auto-created on send, until the thread detail
    // is reloaded. Skip the event when the thread is still on the main
    // worktree (no branch/worktree_path, local mode) to avoid no-op traffic.
    if thread.worktree_path.is_some() || thread.branch.is_some() || thread.env_mode != "local" {
        if let Ok(json) = serde_json::to_string(&thread_git_update_payload(&thread)) {
            run.emit("thread_update", &json);
        }
    }

    run.emit(
        "user_message",
        &serde_json::to_string(&MessageOut::from(user_msg)).unwrap_or_else(|_| "{}".into()),
    );

    // Snapshot the project's worktrees before the agent runs so we can detect
    // ones it creates on its own (e.g. `git worktree add`) and associate the
    // thread with them afterwards.
    let worktree_before = snapshot_worktree_paths(&state, &thread).await;

    // Each turn owns its own plan; clear any stale plan from a previous turn
    // so the UI doesn’t show outdated todos while the model thinks.
    let _ = state.db.delete_plans_for_thread(&thread.id).await;

    let plan_acc = Mutex::new(PlanAccumulator::new());

    let part_callback: PartCallback = Arc::new({
        let run = run.clone();
        let plan_acc = plan_acc;
        move |ev: PartEvent| {
            let original = ev.part().clone();

            // Scan the original text/thinking for plan/todo blocks before
            // stripping the markup, so the sidebar can still update.
            let mut plan_text = original.text_content().unwrap_or("").to_string();
            if let Some(t) = original.thinking_content() {
                plan_text.push_str(t);
            }
            if !plan_text.is_empty() {
                let mut guard = plan_acc.lock().unwrap_or_else(|e| e.into_inner());
                if guard.feed_safe(&plan_text) {
                    if let Some(plan) = guard.current() {
                        let plan = plan.clone();
                        drop(guard);
                        run.set_plan(Some(plan.clone()));
                        if let Ok(json) = serde_json::to_string(&plan) {
                            run.emit("plan_update", &json);
                        }
                    }
                }
            }

            // Remove `<proposed_plan>` / `<update_plan>` XML so the chat does
            // not render raw plan markup.
            let part = original.strip_plan_markup();
            let is_tool_update = ev.is_update() && part.tool_id().is_some();
            let event = if is_tool_update {
                "part_update"
            } else {
                "part"
            };
            let part_json = serde_json::to_string(&part);
            let is_empty_non_tool = match &part {
                MessagePart::Text { content } | MessagePart::Thinking { content } => {
                    content.is_empty()
                }
                MessagePart::ToolCall { .. } => false,
            };
            if !is_empty_non_tool {
                run.apply_part(part, is_tool_update);
                if let Ok(json) = part_json {
                    run.emit(event, &json);
                }
            }
        }
    });
    let permission_callback =
        build_permission_callback(state.clone(), user.id, thread.id.clone(), run.clone());
    let ask_callback = build_ask_callback(state.clone(), user.id, thread.id.clone(), run.clone());

    let provider_result = call_provider(
        &state,
        &user,
        &thread,
        &input,
        Some(permission_callback),
        Some(ask_callback),
        Some(part_callback),
        run.cancelled.clone(),
    )
    .await;

    // If the run was cancelled, persist whatever partial parts the provider
    // produced so the user and the agent retain context of the stopped turn.
    // We also save the session ID so the next message resumes the same ACP
    // session (which preserved its context via $/cancelRequest).
    if run.cancelled.load(Ordering::SeqCst) {
        let (parts, new_session_id, new_title, usage) = match &provider_result {
            Ok(o) => (
                o.parts.clone(),
                o.new_session_id.clone(),
                o.new_title.clone(),
                o.usage.clone(),
            ),
            Err(_) => (
                run.parts.lock().unwrap_or_else(|e| e.into_inner()).clone(),
                None,
                None,
                None,
            ),
        };
        let parts = strip_plan_markup_from_parts(parts);
        if let Some(ref sid) = new_session_id {
            let _ = state
                .db
                .update_thread_session(&thread.id, &thread.provider_id, sid, new_title.as_deref())
                .await;
        }
        if !parts.is_empty() {
            let reply = collect_text(&parts);
            let thinking = collect_thinking(&parts);
            let thinking = (!thinking.is_empty()).then_some(thinking);
            let parts_json = serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into());
            let _ = state
                .db
                .add_message(NewMessage {
                    thread_id: thread.id.clone(),
                    role: "assistant".into(),
                    content: reply,
                    thinking,
                    parts: parts_json,
                    attachments: "[]".into(),
                    model: thread.model.clone(),
                    client_message_id: None,
                })
                .await;
            let _ = state.db.touch_thread(&thread.id).await;
            persist_run_plan(&state.db, &thread.id, &run).await;
        }
        // Tokens spent by a stopped turn still count.
        if let Some(usage) = usage {
            record_run_usage(&state, user.id, &thread, new_session_id, usage).await;
        }
        sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run).await;
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let outcome = match provider_result {
        Ok(o) => o,
        Err(e) => {
            // The model may have already produced useful output before the
            // provider crashed or rate-limited us. Persist that partial
            // assistant reply so the user can see it and the next turn has
            // context, then record the error separately.
            let run_parts = run.parts.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let partial_parts = strip_plan_markup_from_parts(run_parts);
            if !partial_parts.is_empty() {
                if let Err(err) =
                    save_partial_assistant_message(&state, &thread, &partial_parts, &thread.model)
                        .await
                {
                    tracing::error!(error = %err, "failed to persist partial assistant reply");
                }
            }
            let _ = state
                .db
                .add_message(NewMessage {
                    thread_id: thread.id.clone(),
                    role: "error".into(),
                    content: format!("provider error: {e}"),
                    thinking: None,
                    parts: "[]".into(),
                    attachments: "[]".into(),
                    model: String::new(),
                    client_message_id: None,
                })
                .await;
            let _ = state.db.touch_thread(&thread.id).await;
            persist_run_plan(&state.db, &thread.id, &run).await;
            sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run).await;
            return Err(e);
        }
    };

    let ProviderOutcome {
        new_session_id,
        new_title,
        parts,
        usage,
    } = outcome;

    if let Some(usage) = usage {
        record_run_usage(&state, user.id, &thread, new_session_id.clone(), usage).await;
    }

    if run.cancelled.load(Ordering::SeqCst) {
        sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run).await;
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let assistant_msg = match persist_assistant_reply(
        &state,
        &thread,
        user.id,
        &parts,
        new_session_id,
        new_title,
        &run,
    )
    .await
    {
        Ok(m) => m,
        Err(_) => {
            sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run)
                .await;
            return Err(anyhow::anyhow!("failed to save assistant message"));
        }
    };

    persist_run_plan(&state.db, &thread.id, &run).await;

    if run.cancelled.load(Ordering::SeqCst) {
        sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run).await;
        return Err(anyhow::anyhow!("stopped by user"));
    }

    sync_agent_worktree_and_emit(&state, &user, &mut thread, worktree_before.as_ref(), &run).await;

    let _ = run.set_status(RunStatus::Completed).await;
    run.emit(
        "done",
        &serde_json::to_string(&MessageOut::from(assistant_msg)).unwrap_or_else(|_| "{}".into()),
    );

    Ok(())
}

/// Persist the usage snapshot from a completed provider call. The snapshot is
/// cumulative per session, so the db layer diffs it against the stored
/// baseline. Recording failure is logged, never fatal to the run.
async fn record_run_usage(
    state: &AppState,
    user_id: i64,
    thread: &crate::db::ThreadRow,
    new_session_id: Option<String>,
    usage: crate::providers::UsageSnapshot,
) {
    let session_id = new_session_id
        .clone()
        .or_else(|| thread.devin_session_id.clone());
    if let Err(e) = state
        .db
        .record_turn_usage(crate::db::NewUsageEvent {
            user_id,
            thread_id: thread.id.clone(),
            provider_id: thread.provider_id.clone(),
            session_id,
            model: thread.model.clone(),
            snapshot: usage,
            is_new_session: new_session_id.is_some(),
        })
        .await
    {
        tracing::warn!(error = %e, "failed to record turn usage");
    }
}

/// Build the `thread_update` payload carrying a thread's git/worktree
/// metadata. Emitted at the start of every run so the toolbar tracks the
/// worktree the agent actually runs in, even when it was auto-created.
pub(crate) fn thread_git_update_payload(thread: &ThreadRow) -> serde_json::Value {
    serde_json::json!({
        "worktree_path": thread.worktree_path,
        "branch": thread.branch,
        "env_mode": thread.env_mode,
    })
}

/// Detect worktrees the agent created during the run and, when found, persist
/// the new git metadata to the thread and emit a `thread_update` so the
/// toolbar follows the worktree the agent actually works in. Best-effort:
/// failures are logged and never abort the run.
async fn sync_agent_worktree_and_emit(
    state: &AppState,
    user: &crate::db::UserRow,
    thread: &mut ThreadRow,
    before: Option<&std::collections::HashSet<String>>,
    run: &crate::thread_runner::RunState,
) {
    match sync_agent_created_worktree(state, user, thread, before).await {
        Ok(true) => {
            if let Ok(json) = serde_json::to_string(&thread_git_update_payload(thread)) {
                run.emit("thread_update", &json);
            }
        }
        Ok(false) => {}
        Err(e) => tracing::warn!(error = %e, "failed to sync agent-created worktree"),
    }
}

#[cfg(test)]
mod tests {
    use super::{events_stream, thread_git_update_payload};
    use crate::thread_runner::ThreadRunner;
    use axum::body::to_bytes;
    use axum::response::IntoResponse;
    use std::time::Duration;

    #[tokio::test]
    async fn events_stream_returns_sse_with_state_and_events() {
        let runner = ThreadRunner::new();
        let run = runner
            .start("t1".into(), |run| async move {
                run.emit("done", "{}");
                tokio::time::sleep(Duration::from_millis(10)).await;
                Ok(())
            })
            .await
            .unwrap();

        let response = events_stream(run).await.into_response();
        assert_eq!(response.headers()["content-type"], "text/event-stream");

        let body =
            tokio::time::timeout(Duration::from_secs(1), to_bytes(response.into_body(), 4096))
                .await
                .unwrap()
                .unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(text.contains("event: state"), "body: {text}");
        assert!(text.contains("event: done"), "body: {text}");
    }

    use crate::db::ThreadRow;

    fn sample_thread_row() -> ThreadRow {
        ThreadRow {
            id: "t1".into(),
            user_id: 1,
            title: "T".into(),
            devin_session_id: None,
            provider_id: "devin-cli".into(),
            model: "m".into(),
            permission_mode: "normal".into(),
            reasoning_effort: String::new(),
            permissions: None,
            created_at: "2024-01-01T00:00:00Z".into(),
            updated_at: "2024-01-01T00:00:00Z".into(),
            thread_group_id: None,
            project_id: Some(1),
            branch: None,
            worktree_path: None,
            env_mode: "local".into(),
            pinned: false,
            title_user_set: false,
            linked_mr: None,
        }
    }

    #[test]
    fn thread_git_update_payload_serializes_worktree_fields() {
        let mut row = sample_thread_row();
        row.env_mode = "worktree".into();
        row.branch = Some("devinorium/wt-abc".into());
        row.worktree_path = Some("/repo/.devinorium-worktrees/wt-abc".into());

        let payload = thread_git_update_payload(&row);
        assert_eq!(payload["env_mode"], "worktree");
        assert_eq!(payload["branch"], "devinorium/wt-abc");
        assert_eq!(
            payload["worktree_path"],
            "/repo/.devinorium-worktrees/wt-abc"
        );
    }

    #[test]
    fn thread_git_update_payload_serializes_nulls_for_local_mode() {
        let row = sample_thread_row();
        let payload = thread_git_update_payload(&row);
        assert_eq!(payload["env_mode"], "local");
        assert!(payload["branch"].is_null());
        assert!(payload["worktree_path"].is_null());
    }
}
