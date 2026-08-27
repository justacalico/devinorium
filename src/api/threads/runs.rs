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
use super::persistence::{persist_assistant_reply, persist_run_plan};
use super::send::{call_provider, SendInput};
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
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError::new("not found")),
            )
                .into_response();
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
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    }

    match state.thread_runner.stop(&id).await {
        Some(snapshot) => Json(snapshot).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("no active run")),
        )
            .into_response(),
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
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    }

    match state.thread_runner.get(&id).await {
        Some(run) => events_stream(run).await.into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(ApiError::new("no active run")),
        )
            .into_response(),
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

    Sse::new(FuturesStreamExt::boxed(FuturesStreamExt::chain(initial, live)))
}

pub(crate) async fn run_thread(
    state: AppState,
    run: Arc<RunState>,
    user: UserRow,
    thread: ThreadRow,
    input: SendInput,
    user_msg: MessageRow,
) -> anyhow::Result<()> {
    run.emit(
        "user_message",
        &serde_json::to_string(&MessageOut::from(user_msg)).unwrap_or_else(|_| "{}".into()),
    );

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
            let event = if is_tool_update { "part_update" } else { "part" };
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
    let ask_callback =
        build_ask_callback(state.clone(), user.id, thread.id.clone(), run.clone());

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
        let (parts, new_session_id, new_title) = match &provider_result {
            Ok(t) => (t.2.clone(), t.0.clone(), t.1.clone()),
            Err(_) => (
                run.parts
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clone(),
                None,
                None,
            ),
        };
        let parts = strip_plan_markup_from_parts(parts);
        if let Some(ref sid) = new_session_id {
            let _ = state
                .db
                .update_thread_session(&thread.id, sid, new_title.as_deref())
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
                })
                .await;
            let _ = state.db.touch_thread(&thread.id).await;
            persist_run_plan(&state.db, &thread.id, &run).await;
        }
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let (new_session_id, new_title, parts) = match provider_result {
        Ok(t) => t,
        Err(e) => {
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
                })
                .await;
            let _ = state.db.touch_thread(&thread.id).await;
            return Err(e);
        }
    };

    if run.cancelled.load(Ordering::SeqCst) {
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let assistant_msg = persist_assistant_reply(
        &state,
        &thread,
        user.id,
        &parts,
        new_session_id,
        new_title,
        &run,
    )
    .await
    .map_err(|_| anyhow::anyhow!("failed to save assistant message"))?;

    persist_run_plan(&state.db, &thread.id, &run).await;

    if run.cancelled.load(Ordering::SeqCst) {
        return Err(anyhow::anyhow!("stopped by user"));
    }

    let _ = run.set_status(RunStatus::Completed).await;
    run.emit(
        "done",
        &serde_json::to_string(&MessageOut::from(assistant_msg)).unwrap_or_else(|_| "{}".into()),
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::events_stream;
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
        assert_eq!(
            response.headers()["content-type"],
            "text/event-stream"
        );

        let body = tokio::time::timeout(
            Duration::from_secs(1),
            to_bytes(response.into_body(), 4096),
        )
        .await
        .unwrap()
        .unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(text.contains("event: state"), "body: {text}");
        assert!(text.contains("event: done"), "body: {text}");
    }
}
