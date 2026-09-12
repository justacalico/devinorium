//! Send pipeline: parse multipart input, persist the user message, and start
//! the provider run whose events stream back over SSE.

use std::sync::Arc;

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::map_err_internal;
use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::db::messages::MAX_CLIENT_MESSAGE_ID_LEN;
use crate::db::{DuplicateClientMessageId, ThreadRow};
use crate::providers::{
    AskCallback, Attachment, MessagePart, PartCallback, PermissionCallback, SendOptions,
    SendRequest, SessionCallback, StartRequest, UsageSnapshot,
};
use crate::AppState;

use super::context_refs::{prompt_with_refs, resolve_context_refs, ContextPathIn, ContextRef};
use super::persistence::persist_user_message;
use super::plan::{normalize_mode, project_working_dir_for_thread};
use super::runs::{events_stream, run_thread};
use super::thread_refs::{prompt_with_thread_refs, resolve_thread_refs, ThreadRef};
use super::worktree::ensure_thread_worktree;

pub(super) async fn send_stream(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let mut thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
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

    let mut input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };
    resolve_context_refs(&state, &thread, &mut input).await;
    resolve_thread_refs(&state, user.id, &thread, &mut input).await;
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

    let user_msg = match persist_user_message(&state, &thread, &input).await {
        Ok(m) => m,
        Err(e) => {
            if e.downcast_ref::<DuplicateClientMessageId>().is_some() {
                return (
                    StatusCode::CONFLICT,
                    Json(ApiError::new("message with this client id already exists")),
                )
                    .into_response();
            }
            return map_err_internal(e).into_response();
        }
    };
    let user_msg_id = user_msg.id;

    let run = match state
        .thread_runner
        .start(id.clone(), {
            let state = state.clone();
            move |run| run_thread(state, run, user, thread, input, user_msg)
        })
        .await
    {
        Ok(run) => run,
        Err(crate::thread_runner::StartError::AlreadyRunning) => {
            // Roll back the user message we just inserted; the client will
            // restore its composer and retry/resume instead.
            if let Err(e) = state.db.delete_message(user_msg_id).await {
                tracing::error!(error = %e, "failed to roll back optimistic user message");
                return map_err_internal(e).into_response();
            }
            return (
                StatusCode::CONFLICT,
                Json(ApiError::new("thread is already running")),
            )
                .into_response();
        }
    };

    events_stream(run).await.into_response()
}

#[derive(Debug, Clone)]
pub(crate) struct SendInput {
    pub prompt: String,
    pub mode: String,
    pub attachments: Vec<Attachment>,
    pub att_meta: Vec<serde_json::Value>,
    pub client_message_id: Option<String>,
    /// Raw context paths sent by the client (files panel drag & drop).
    pub context_paths: Vec<ContextPathIn>,
    /// Context paths resolved against the project root; filled in by
    /// `context_refs::resolve_context_refs` before the message is persisted.
    pub context_refs: Vec<ContextRef>,
    /// Raw thread ids sent by the client (sidebar drag & drop).
    pub referenced_thread_ids: Vec<String>,
    /// Referenced threads with their recent history; filled in by
    /// `thread_refs::resolve_thread_refs` before the message is persisted.
    pub thread_refs: Vec<ThreadRef>,
}

pub(crate) fn sanitize_sse_data(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n")
}

pub(crate) async fn parse_send_multipart(mut multipart: Multipart) -> Result<SendInput, Response> {
    let mut prompt: Option<String> = None;
    let mut mode: String = "code".to_string();
    let mut client_message_id: Option<String> = None;
    let mut attachments: Vec<Attachment> = Vec::new();
    let mut att_meta: Vec<serde_json::Value> = Vec::new();
    let mut context_paths: Vec<ContextPathIn> = Vec::new();
    let mut referenced_thread_ids: Vec<String> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let mime = field
            .content_type()
            .unwrap_or("application/octet-stream")
            .to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return Err(map_err_internal(e).into_response()),
        };
        if name == "prompt" {
            prompt = Some(String::from_utf8_lossy(&bytes).to_string());
        } else if name == "mode" {
            let raw = String::from_utf8_lossy(&bytes).to_string();
            mode = normalize_mode(&raw);
        } else if name == "client_message_id" {
            let s = String::from_utf8_lossy(&bytes).to_string();
            if s.len() > MAX_CLIENT_MESSAGE_ID_LEN {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new("client_message_id too long")),
                )
                    .into_response());
            }
            if !s.is_empty() {
                client_message_id = Some(s);
            }
        } else if name == "context_paths" {
            let raw = String::from_utf8_lossy(&bytes).to_string();
            match super::context_refs::parse_context_paths(&raw) {
                Ok(paths) => context_paths.extend(paths),
                Err(e) => {
                    return Err((StatusCode::BAD_REQUEST, Json(ApiError::new(&e))).into_response())
                }
            }
        } else if name == "referenced_thread_ids" {
            let raw = String::from_utf8_lossy(&bytes).to_string();
            match super::thread_refs::parse_referenced_thread_ids(&raw) {
                Ok(ids) => referenced_thread_ids.extend(ids),
                Err(e) => {
                    return Err((StatusCode::BAD_REQUEST, Json(ApiError::new(&e))).into_response())
                }
            }
        } else if !filename.is_empty() {
            if bytes.len() > 8 * 1024 * 1024 {
                return Err((
                    StatusCode::PAYLOAD_TOO_LARGE,
                    Json(ApiError::new("attachment too large (max 8 MiB)")),
                )
                    .into_response());
            }
            att_meta.push(serde_json::json!({
                "filename": filename,
                "mime": mime,
                "size": bytes.len(),
                // Position in `attachments`; lets clients fetch the stored
                // blob from the attachment endpoint.
                "index": attachments.len(),
            }));
            attachments.push(Attachment {
                filename: filename.clone(),
                mime,
                data: bytes.to_vec(),
            });
        }
    }
    let prompt = match prompt {
        Some(p) if !p.trim().is_empty() => p,
        // References alone are a valid message: the context block makes up
        // the effective prompt sent to the provider.
        _ if !context_paths.is_empty() || !referenced_thread_ids.is_empty() => String::new(),
        _ => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("prompt is required")),
            )
                .into_response())
        }
    };
    if prompt.chars().count() > 64 * 1024 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("prompt too long (max 64K characters)")),
        )
            .into_response());
    }
    Ok(SendInput {
        prompt,
        mode,
        attachments,
        att_meta,
        client_message_id,
        context_paths,
        context_refs: Vec::new(),
        referenced_thread_ids,
        thread_refs: Vec::new(),
    })
}

/// What a completed provider call produced, beyond the message parts.
pub(crate) struct ProviderOutcome {
    /// Session id when the provider created a new session this run.
    pub new_session_id: Option<String>,
    pub new_title: Option<String>,
    pub parts: Vec<MessagePart>,
    /// Cumulative usage reported by the provider, if any.
    pub usage: Option<UsageSnapshot>,
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn call_provider(
    state: &AppState,
    user: &crate::db::UserRow,
    thread: &ThreadRow,
    input: &SendInput,
    permission_callback: Option<PermissionCallback>,
    ask_callback: Option<AskCallback>,
    part_callback: Option<PartCallback>,
    cancel_signal: Arc<std::sync::atomic::AtomicBool>,
) -> anyhow::Result<ProviderOutcome> {
    let provider = state.provider_for(user, &thread.provider_id);
    let working_dir = project_working_dir_for_thread(state, thread).await?;

    // The callback stays attached for follow-ups too: some providers (codex)
    // only learn the durable session id after the first turn runs, so a
    // later correction must be able to overwrite a stale stored id.
    let session_callback: Option<SessionCallback> = {
        let thread_id = thread.id.clone();
        let provider_id = thread.provider_id.clone();
        let state_for_session = state.clone();
        Some({
            let cb: SessionCallback = Arc::new(move |sid: String| {
                let state = state_for_session.clone();
                let thread_id = thread_id.clone();
                let provider_id = provider_id.clone();
                Box::pin(async move {
                    if let Err(err) = state
                        .db
                        .update_thread_session(&thread_id, &provider_id, &sid, None)
                        .await
                    {
                        tracing::error!(error = %err, "failed to persist session id");
                    }
                })
            });
            cb
        })
    };

    let options = SendOptions {
        model: thread.model.clone(),
        reasoning_effort: if thread.reasoning_effort.is_empty() {
            None
        } else {
            Some(thread.reasoning_effort.clone())
        },
        working_dir,
        permission_mode: thread.permission_mode.clone(),
        permissions: thread.permissions.clone(),
        attachments: input.attachments.clone(),
        permission_callback,
        ask_callback,
        part_callback,
        session_callback,
        interaction_mode: input.mode.clone(),
        cancel_signal: Some(cancel_signal),
    };

    let prompt = prompt_with_thread_refs(
        &prompt_with_refs(&input.prompt, &input.context_refs),
        &input.thread_refs,
    );
    if let Some(sid) = thread.devin_session_id.as_ref() {
        provider
            .send(SendRequest {
                session_id: sid.clone(),
                prompt,
                options,
            })
            .await
            .map(|r| ProviderOutcome {
                new_session_id: None,
                new_title: None,
                parts: r.parts,
                usage: r.usage,
            })
    } else {
        provider
            .start(StartRequest { prompt, options })
            .await
            .map(|r| ProviderOutcome {
                new_session_id: Some(r.session_id),
                new_title: Some(r.title),
                parts: r.parts,
                usage: r.usage,
            })
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_send_multipart, sanitize_sse_data};
    use axum::body::Body;
    use axum::extract::{FromRequest, Multipart};
    use axum::http::{Request, StatusCode};

    #[test]
    fn sanitize_sse_data_normalizes_newlines() {
        assert_eq!(
            sanitize_sse_data("line1\r\nline2\rline3"),
            "line1\nline2\nline3"
        );
        assert_eq!(sanitize_sse_data("plain\n"), "plain\n");
    }

    #[tokio::test]
    async fn parse_send_multipart_extracts_prompt_mode_client_id_and_attachment() {
        let body = "--boundary\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            hello\r\n\
            --boundary\r\n\
            Content-Disposition: form-data; name=\"mode\"\r\n\r\n\
            plan\r\n\
            --boundary\r\n\
            Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
            cm-123\r\n\
            --boundary\r\n\
            Content-Disposition: form-data; name=\"attachment\"; filename=\"note.txt\"\r\n\
            Content-Type: text/plain\r\n\r\n\
            file body\r\n\
            --boundary--\r\n";
        let req = Request::builder()
            .method("POST")
            .header("content-type", "multipart/form-data; boundary=boundary")
            .body(Body::from(body.as_bytes().to_vec()))
            .unwrap();
        let multipart = Multipart::from_request(req, &()).await.unwrap();
        let input = parse_send_multipart(multipart).await.unwrap();
        assert_eq!(input.prompt, "hello");
        assert_eq!(input.mode, "plan");
        assert_eq!(input.client_message_id.as_deref(), Some("cm-123"));
        assert_eq!(input.attachments.len(), 1);
        assert_eq!(input.attachments[0].filename, "note.txt");
        assert_eq!(input.attachments[0].data, b"file body");
        assert_eq!(input.att_meta[0]["filename"], "note.txt");
        // The metadata index is the upload's position among sent files; the
        // attachment endpoint serves the blob under that key.
        assert_eq!(input.att_meta[0]["index"], 0);
    }

    #[tokio::test]
    async fn parse_send_multipart_rejects_too_long_client_id() {
        let long_id = "x".repeat(65);
        let body = format!(
            "--boundary\r\n\
            Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\
            hello\r\n\
            --boundary\r\n\
            Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n\
            {long_id}\r\n\
            --boundary--\r\n"
        );
        let req = Request::builder()
            .method("POST")
            .header("content-type", "multipart/form-data; boundary=boundary")
            .body(Body::from(body.into_bytes()))
            .unwrap();
        let multipart = Multipart::from_request(req, &()).await.unwrap();
        let resp = parse_send_multipart(multipart).await.unwrap_err();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}
