//! Persist user messages, assistant replies, and run plans.

use std::path::Path;
use std::sync::atomic::Ordering;

use axum::response::{IntoResponse, Response};

use crate::api::map_err_internal;
use crate::db::{MessageRow, NewMessage, ThreadRow};
use crate::git::{first_gitlab_merge_request_url, parse_gitlab_remote_url};
use crate::plan::Plan;
use crate::providers::{
    collect_text, collect_thinking, strip_plan_markup_from_parts, title_from_prompt, MessagePart,
};
use crate::thread_runner::{RunState, ThreadRunner};
use crate::AppState;

use super::send::SendInput;

pub(crate) async fn persist_user_message(
    state: &AppState,
    thread: &ThreadRow,
    input: &SendInput,
) -> anyhow::Result<MessageRow> {
    let user_parts = serde_json::to_string(&[MessagePart::text(input.prompt.as_str())])
        .unwrap_or_else(|_| "[]".into());
    state
        .db
        .add_message(NewMessage {
            thread_id: thread.id.clone(),
            role: "user".into(),
            content: input.prompt.clone(),
            thinking: None,
            parts: user_parts,
            attachments: serde_json::to_string(&input.att_meta).unwrap_or_else(|_| "[]".into()),
            model: String::new(),
            client_message_id: input.client_message_id.clone(),
        })
        .await
}

/// Derive a title from the first user message and persist it, but only if the
/// user has not already set a title manually. Returns `true` when the title
/// was updated.
pub(crate) async fn update_thread_title_from_send(
    state: &AppState,
    user_id: i64,
    thread: &mut ThreadRow,
    input: &SendInput,
) -> anyhow::Result<bool> {
    let title = title_from_prompt(&input.prompt);
    if let Some(updated_at) = state
        .db
        .update_title_from_send(&thread.id, user_id, &title)
        .await?
    {
        thread.title = title;
        thread.updated_at = updated_at;
        thread.title_user_set = true;
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Links a thread to the first merge request URL found in an assistant reply,
/// but only if the thread has no linked MR and the URL matches the thread's
/// project remote. Failures are logged and ignored so a bad URL never breaks
/// the turn.
async fn auto_link_thread_merge_request(
    state: &AppState,
    thread: &ThreadRow,
    user_id: i64,
    content: &str,
) {
    let Some(linked) = first_gitlab_merge_request_url(content) else {
        return;
    };

    let project_id = match thread.project_id {
        Some(pid) => pid,
        None => return,
    };
    let project = match state.db.get_project(project_id, user_id).await {
        Ok(Some(p)) => p,
        Ok(None) => return,
        Err(e) => {
            tracing::warn!(error = %e, "failed to load project for auto-link");
            return;
        }
    };

    let remote_url = match state.git.remote_url(Path::new(&project.path)).await {
        Ok(u) => u,
        Err(crate::git::GitError::NotEnabled | crate::git::GitError::NotRepo) => return,
        Err(e) => {
            tracing::warn!(error = %e, "failed to read project remote for auto-link");
            return;
        }
    };

    let remote = match parse_gitlab_remote_url(&remote_url) {
        Some(r) => r,
        None => return,
    };

    if linked.hostname != remote.hostname || linked.project_path != remote.project_path {
        tracing::debug!(
            linked_hostname = %linked.hostname,
            linked_project = %linked.project_path,
            remote_hostname = %remote.hostname,
            remote_project = %remote.project_path,
            "auto-link merge request does not match project remote"
        );
        return;
    }

    let json = match serde_json::to_string(&linked) {
        Ok(j) => j,
        Err(e) => {
            tracing::warn!(error = %e, "failed to serialize linked merge request");
            return;
        }
    };

    // Only write the link when the row still has no linked MR, preventing a
    // manual link set while the run was in-flight from being clobbered.
    if let Err(e) = sqlx::query(
        "UPDATE threads
         SET linked_mr = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
         WHERE id = ? AND user_id = ? AND linked_mr IS NULL",
    )
    .bind(json)
    .bind(&thread.id)
    .bind(user_id)
    .execute(state.db.pool())
    .await
    {
        tracing::warn!(error = %e, "failed to persist auto-linked merge request");
    }
}

pub(crate) async fn persist_assistant_reply(
    state: &AppState,
    thread: &ThreadRow,
    user_id: i64,
    parts: &[MessagePart],
    new_session_id: Option<String>,
    new_title: Option<String>,
    run: &RunState,
) -> Result<MessageRow, Response> {
    if run.cancelled.load(Ordering::SeqCst) {
        return Err(map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

    let session_id_for_audit = new_session_id.clone();
    if let Some(sid) = new_session_id {
        if run.cancelled.load(Ordering::SeqCst) {
            return Err(map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
        }
        let _ = state
            .db
            .update_thread_session(&thread.id, &thread.provider_id, &sid, new_title.as_deref())
            .await;
    }

    if run.cancelled.load(Ordering::SeqCst) {
        return Err(map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }
    let _ = state.db.touch_thread(&thread.id).await;

    if run.cancelled.load(Ordering::SeqCst) {
        return Err(map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

    // Strip plan XML from persisted parts so the final assistant message does
    // not show raw `<proposed_plan>` / `<update_plan>` markup. Coalescing
    // consecutive text/thinking parts first handles plan blocks split across
    // chunks.
    let stripped = strip_plan_markup_from_parts(parts.to_vec());
    let reply = collect_text(&stripped);
    let thinking = collect_thinking(&stripped);
    let thinking = (!thinking.is_empty()).then_some(thinking);
    let parts_json = serde_json::to_string(&stripped).unwrap_or_else(|_| "[]".into());
    let assistant_msg = state
        .db
        .add_message(NewMessage {
            thread_id: thread.id.clone(),
            role: "assistant".into(),
            content: reply.clone(),
            thinking,
            parts: parts_json,
            attachments: "[]".into(),
            model: thread.model.clone(),
            client_message_id: None,
        })
        .await
        .map_err(|e| map_err_internal(e).into_response())?;

    if run.cancelled.load(Ordering::SeqCst) {
        let _ = state.db.delete_message(assistant_msg.id).await;
        return Err(map_err_internal(anyhow::anyhow!("stopped by user")).into_response());
    }

    auto_link_thread_merge_request(state, thread, user_id, &reply).await;

    let _ = state
        .db
        .audit(
            Some(user_id),
            "thread.send",
            &serde_json::json!({"thread_id": thread.id, "session_id": session_id_for_audit}),
            None,
        )
        .await;

    Ok(assistant_msg)
}

/// Persist a partial or final assistant reply from the accumulated run parts.
///
/// Unlike `persist_assistant_reply`, this does not update the thread session or
/// audit the request, so it is safe to call when the provider has failed or the
/// turn was cancelled mid-generation.
pub(crate) async fn save_partial_assistant_message(
    state: &AppState,
    thread: &ThreadRow,
    parts: &[MessagePart],
    model: &str,
) -> anyhow::Result<MessageRow> {
    let stripped = strip_plan_markup_from_parts(parts.to_vec());
    let reply = collect_text(&stripped);
    let thinking = collect_thinking(&stripped);
    let thinking = (!thinking.is_empty()).then_some(thinking);
    let parts_json = serde_json::to_string(&stripped).unwrap_or_else(|_| "[]".into());
    let msg = state
        .db
        .add_message(NewMessage {
            thread_id: thread.id.clone(),
            role: "assistant".into(),
            content: reply,
            thinking,
            parts: parts_json,
            attachments: "[]".into(),
            model: model.into(),
            client_message_id: None,
        })
        .await?;
    let _ = state.db.touch_thread(&thread.id).await;
    Ok(msg)
}

/// Persist the final active plan for a run to the database, if any.
pub(crate) async fn persist_run_plan(db: &crate::db::Db, thread_id: &str, run: &RunState) {
    let plan = run.plan.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(plan) = plan {
        let _ = db
            .upsert_latest_plan(thread_id, Some(&run.run_id), &plan)
            .await;
    }
}

/// Return the plan currently held by an active run for `thread_id`. The first
/// tuple element is true when a run is still in the runner, and the second
/// element is its current plan (if the model has emitted one yet).
pub(crate) async fn active_run_plan(
    thread_runner: &ThreadRunner,
    thread_id: &str,
) -> (bool, Option<Plan>) {
    let Some(run) = thread_runner.get(thread_id).await else {
        return (false, None);
    };
    let plan = run.plan.lock().unwrap_or_else(|e| e.into_inner()).clone();
    (true, plan)
}

#[cfg(test)]
mod tests {
    use super::active_run_plan;
    use crate::plan::{Plan, PlanStep, PlanStepStatus};
    use crate::thread_runner::ThreadRunner;

    #[tokio::test]
    async fn active_run_plan_reports_runner_plan() {
        let runner = ThreadRunner::new();
        assert_eq!(active_run_plan(&runner, "missing").await, (false, None));

        let run = runner
            .start("t1".into(), |_run| async { Ok(()) })
            .await
            .unwrap();
        let plan = Plan::new(None, vec![PlanStep::new("step 1", PlanStepStatus::Pending)]);
        run.set_plan(Some(plan.clone()));

        let (active, got) = active_run_plan(&runner, "t1").await;
        assert!(active);
        assert_eq!(got, Some(plan));
    }
}
