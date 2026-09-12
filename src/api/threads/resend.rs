//! Resend a turn: regenerate the assistant reply for an existing user
//! message, or edit a user message and replay the thread from that point.

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::map_err_internal;
use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::db::MessageRow;
use crate::providers::Attachment;
use crate::AppState;

use super::context_refs::{resolve_context_refs, ContextPathIn};
use super::persistence::persist_user_message;
use super::runs::{events_stream, run_thread};
use super::send::{read_send_fields, send_input_from_fields, SendInput};
use super::thread_refs::resolve_thread_refs;
use super::worktree::ensure_thread_worktree;

/// POST `/api/threads/:id/messages/:message_id/resend`
///
/// A multipart body with a `prompt` field edits that user message and
/// replays the thread from it (the old message and everything after it is
/// deleted). Without `prompt` the request regenerates the reply: the turn's
/// anchoring user message is kept, everything after it is deleted, and the
/// stored prompt is sent to the provider again.
///
/// Deletion happens inside the run task rather than in the handler so a
/// `start` rejection (another run active) can never lose rows.
///
/// Note the provider session is not rewound: `provider.send` appends to the
/// existing session, so the model may retain context of the replaced turn.
pub(super) async fn resend(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((id, message_id)): Path<(String, i64)>,
    multipart: Multipart,
) -> Response {
    let mut thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    if let Err(e) = ensure_thread_worktree(&state, &user, &mut thread).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiError::new(format!("worktree setup failed: {e}"))),
        )
            .into_response();
    }

    let anchor = match state.db.get_message_full(&id, message_id).await {
        Ok(Some(m)) => m,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    let fields = match read_send_fields(multipart).await {
        Ok(f) => f,
        Err(resp) => return resp,
    };
    let editing = fields.prompt.is_some();

    // The user message the replay is anchored on. An edit can only replace
    // a user message; a regenerate resolves the clicked message's turn back
    // to its user anchor (assistant and error rows both work).
    let anchor = if editing {
        if anchor.role != "user" {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("only a user message can be edited")),
            )
                .into_response();
        }
        anchor
    } else if anchor.role == "user" {
        anchor
    } else {
        match state.db.turn_user_message(&id, anchor.turn_id).await {
            Ok(Some(m)) => m,
            Ok(None) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new("no user message to resend for this turn")),
                )
                    .into_response()
            }
            Err(e) => return map_err_internal(e).into_response(),
        }
    };

    let mut input = if editing {
        // Keep the stored message's path/thread references: an edit only
        // changes the text, so the references are rebuilt alongside it.
        let (paths, tids) = stored_refs(&anchor);
        let mut fields = fields;
        fields.context_paths.extend(paths);
        fields.referenced_thread_ids.extend(tids);
        let mut input = match send_input_from_fields(fields) {
            Ok(i) => i,
            Err(resp) => return resp,
        };
        match reattach_stored_files(&state, &anchor, &mut input).await {
            Ok(()) => input,
            Err(e) => return map_err_internal(e).into_response(),
        }
    } else {
        regen_input(&anchor, fields.mode)
    };
    resolve_context_refs(&state, &thread, &mut input).await;
    resolve_thread_refs(&state, user.id, &thread, &mut input).await;

    // Nothing to send: the resolved prompt and every reference came up
    // empty (e.g. a refs-only message whose paths no longer exist).
    if input.prompt.trim().is_empty()
        && input.context_refs.is_empty()
        && input.thread_refs.is_empty()
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("prompt is required")),
        )
            .into_response();
    }

    let run = match state
        .thread_runner
        .start(id.clone(), {
            let state = state.clone();
            move |run| async move {
                if editing {
                    // Persist the replacement first so a delete failure
                    // never loses it; if the delete fails, roll the new row
                    // back so the thread keeps its original shape.
                    let user_msg = persist_user_message(&state, &thread, &input).await?;
                    if let Err(e) = state
                        .db
                        .delete_messages_from_except(&id, anchor.id, user_msg.id)
                        .await
                    {
                        let _ = state.db.delete_message(user_msg.id).await;
                        return Err(e);
                    }
                    emit_truncated(&run, &id);
                    run_thread(state, run, user, thread, input, user_msg).await
                } else {
                    state.db.delete_messages_after(&id, anchor.id).await?;
                    emit_truncated(&run, &id);
                    run_thread(state, run, user, thread, input, anchor).await
                }
            }
        })
        .await
    {
        Ok(run) => run,
        Err(crate::thread_runner::StartError::AlreadyRunning) => {
            return (
                StatusCode::CONFLICT,
                Json(ApiError::new("thread is already running")),
            )
                .into_response();
        }
    };

    events_stream(run).await.into_response()
}

/// Tell run subscribers the tail was deleted so clients watching from
/// another tab or device can resync instead of showing ghost rows.
fn emit_truncated(run: &crate::thread_runner::RunState, thread_id: &str) {
    let payload = serde_json::json!({ "thread_id": thread_id });
    run.emit("messages_truncated", &payload.to_string());
}

/// The path and thread references stored on a user message, rebuilt so they
/// can be re-resolved against the current project state.
fn stored_refs(anchor: &MessageRow) -> (Vec<ContextPathIn>, Vec<String>) {
    let attachments: serde_json::Value =
        serde_json::from_str(&anchor.attachments).unwrap_or(serde_json::json!([]));
    let mut context_paths = Vec::new();
    let mut referenced_thread_ids = Vec::new();
    for item in attachments.as_array().into_iter().flatten() {
        match item.get("kind").and_then(|k| k.as_str()) {
            Some("path") => {
                if let Some(path) = item.get("filename").and_then(|f| f.as_str()) {
                    context_paths.push(ContextPathIn {
                        path: path.to_string(),
                        is_dir: item
                            .get("is_dir")
                            .and_then(|d| d.as_bool())
                            .unwrap_or(false),
                    });
                }
            }
            Some("thread") => {
                if let Some(tid) = item.get("thread_id").and_then(|t| t.as_str()) {
                    referenced_thread_ids.push(tid.to_string());
                }
            }
            _ => {}
        }
    }
    (context_paths, referenced_thread_ids)
}

/// File entries in a stored message's attachment metadata (path and thread
/// references have a `kind` and are handled separately), sorted by index.
fn stored_file_metas(anchor: &MessageRow) -> Vec<serde_json::Value> {
    let attachments: serde_json::Value =
        serde_json::from_str(&anchor.attachments).unwrap_or(serde_json::json!([]));
    let mut metas: Vec<serde_json::Value> = attachments
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| {
            !matches!(
                item.get("kind").and_then(|k| k.as_str()),
                Some("path") | Some("thread")
            )
        })
        .cloned()
        .collect();
    metas.sort_by_key(|m| m.get("index").and_then(|i| i.as_i64()).unwrap_or(0));
    metas
}

/// Move the anchor's stored file uploads onto the resend input so the
/// rewritten message keeps its chips, blobs, and provider file context.
async fn reattach_stored_files(
    state: &AppState,
    anchor: &MessageRow,
    input: &mut SendInput,
) -> anyhow::Result<()> {
    let mut blobs = state.db.list_message_attachments(anchor.id).await?;
    let mut metas = stored_file_metas(anchor);
    // Blobs and metas zip by position; drop whichever side ran short (a
    // failed blob insert at send time leaves chips without data).
    metas.truncate(blobs.len());
    blobs.truncate(metas.len());
    if blobs.is_empty() {
        return Ok(());
    }
    let base = blobs.len() as i64;
    for (i, m) in metas.iter_mut().enumerate() {
        m["index"] = serde_json::json!(i as i64);
    }
    for m in input.att_meta.iter_mut() {
        if let Some(idx) = m.get_mut("index").and_then(|i| i.as_i64()) {
            m["index"] = serde_json::json!(idx + base);
        }
    }
    input.attachments.splice(
        0..0,
        blobs.into_iter().map(|b| Attachment {
            filename: b.filename,
            mime: b.mime,
            data: b.data,
        }),
    );
    metas.append(&mut input.att_meta);
    input.att_meta = metas;
    Ok(())
}

/// Rebuild a [SendInput] from a stored user message for regeneration.
fn regen_input(anchor: &MessageRow, mode: String) -> SendInput {
    let (context_paths, referenced_thread_ids) = stored_refs(anchor);
    SendInput {
        prompt: anchor.content.clone(),
        mode,
        attachments: Vec::new(),
        att_meta: Vec::new(),
        client_message_id: None,
        context_paths,
        context_refs: Vec::new(),
        referenced_thread_ids,
        thread_refs: Vec::new(),
    }
}
