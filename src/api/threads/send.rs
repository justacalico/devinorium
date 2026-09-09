//! Send pipeline: parse multipart input, persist the user message, start the
//! provider run, and build the reply payload.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::map_err_internal;
use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::db::messages::MAX_CLIENT_MESSAGE_ID_LEN;
use crate::db::{DuplicateClientMessageId, MessageRow, ThreadRow};
use crate::providers::{
    AskCallback, Attachment, MessagePart, PartCallback, PermissionCallback, SendOptions,
    SendRequest, SessionCallback, StartRequest, UsageSnapshot,
};
use crate::thread_runner::{RunEvent, RunStatus};
use crate::AppState;

use super::persistence::persist_user_message;
use super::plan::{normalize_mode, project_working_dir_for_thread};
use super::runs::{events_stream, run_thread};
use super::MessageOut;

pub(super) async fn send(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    let input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };

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

    let mut rx = match run.subscribe() {
        Some(rx) => rx,
        None => {
            // The run finished before we could subscribe. Return the final
            // result based on the run status and any persisted messages.
            let status = *run.status.read().await;
            return match status {
                RunStatus::Stopped => Json(serde_json::json!({ "stopped": true })).into_response(),
                RunStatus::Completed => {
                    let messages = state
                        .db
                        .list_messages_full(&id, 2)
                        .await
                        .unwrap_or_default();
                    if let Some(reply) = build_send_reply(&messages) {
                        return reply;
                    }
                    (
                        StatusCode::BAD_GATEWAY,
                        Json(ApiError::new("provider error")),
                    )
                        .into_response()
                }
                RunStatus::Failed => {
                    let error = run
                        .error
                        .read()
                        .await
                        .clone()
                        .unwrap_or_else(|| "provider error".into());
                    (StatusCode::BAD_GATEWAY, Json(ApiError::new(&error))).into_response()
                }
                RunStatus::Running | RunStatus::Idle => (
                    StatusCode::SERVICE_UNAVAILABLE,
                    Json(ApiError::new("run already closed")),
                )
                    .into_response(),
            };
        }
    };
    let mut stopped = false;
    let mut permission_request = None;
    let mut ask_request = None;
    loop {
        match tokio::time::timeout(Duration::from_secs(30 * 60), rx.recv()).await {
            Ok(Ok(RunEvent { event, .. })) if event == "done" => break,
            Ok(Ok(RunEvent { event, .. })) if event == "stopped" => {
                stopped = true;
                break;
            }
            Ok(Ok(RunEvent { event, data, .. })) if event == "error" => {
                return (StatusCode::BAD_GATEWAY, Json(ApiError::new(&data))).into_response();
            }
            Ok(Ok(RunEvent { event, data, .. })) if event == "permission_request" => {
                permission_request = Some(data);
                break;
            }
            Ok(Ok(RunEvent { event, data, .. })) if event == "ask_request" => {
                ask_request = Some(data);
                break;
            }
            Ok(Ok(_)) => continue,
            Ok(Err(_)) => break,
            Err(_) => {
                return (
                    StatusCode::GATEWAY_TIMEOUT,
                    Json(ApiError::new("run did not finish in time")),
                )
                    .into_response();
            }
        }
    }

    if stopped {
        return Json(serde_json::json!({ "stopped": true })).into_response();
    }

    let status = *run.status.read().await;
    if status == RunStatus::Stopped {
        return Json(serde_json::json!({ "stopped": true })).into_response();
    }

    if let Some(data) = permission_request {
        return (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({ "permission_request": data })),
        )
            .into_response();
    }

    if let Some(data) = ask_request {
        return (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({ "ask_request": data })),
        )
            .into_response();
    }

    let messages = state
        .db
        .list_messages_full(&id, 2)
        .await
        .unwrap_or_default();
    if let Some(reply) = build_send_reply(&messages) {
        return reply;
    }

    (
        StatusCode::BAD_GATEWAY,
        Json(ApiError::new("provider error")),
    )
        .into_response()
}

pub(super) async fn send_stream(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
    multipart: Multipart,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    };

    let input = match parse_send_multipart(multipart).await {
        Ok(parsed) => parsed,
        Err(resp) => return resp,
    };

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
}

pub(crate) fn build_send_reply(messages: &[MessageRow]) -> Option<Response> {
    if messages.len() < 2 {
        return None;
    }
    let user_msg = &messages[messages.len() - 2];
    let assistant_msg = &messages[messages.len() - 1];
    if user_msg.role != "user" || assistant_msg.role != "assistant" {
        return None;
    }
    Some(
        Json(serde_json::json!({
            "user_message": MessageOut::from(user_msg.clone()),
            "assistant_message": MessageOut::from(assistant_msg.clone()),
            "reply": assistant_msg.content,
            "thinking": assistant_msg.thinking,
        }))
        .into_response(),
    )
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

    if let Some(sid) = thread.devin_session_id.as_ref() {
        provider
            .send(SendRequest {
                session_id: sid.clone(),
                prompt: input.prompt.clone(),
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
            .start(StartRequest {
                prompt: input.prompt.clone(),
                options,
            })
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
    use super::{build_send_reply, parse_send_multipart, sanitize_sse_data};
    use crate::db::MessageRow;
    use crate::providers::MessagePart;
    use axum::body::{to_bytes, Body};
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

    #[test]
    fn build_send_reply_requires_user_then_assistant() {
        let user = MessageRow {
            id: 1,
            thread_id: "t1".into(),
            role: "user".into(),
            content: "hello".into(),
            thinking: None,
            parts: Some(serde_json::to_string(&[MessagePart::text("hello")]).unwrap()),
            attachments: "[]".into(),
            model: "m".into(),
            client_message_id: None,
            created_at: "now".into(),
            turn_id: 1,
            seq: 1,
            content_length: 5,
            parts_length: Some(0),
        };
        let assistant = MessageRow {
            id: 2,
            thread_id: "t1".into(),
            role: "assistant".into(),
            content: "reply".into(),
            thinking: Some("thinking".into()),
            parts: Some(serde_json::to_string(&[MessagePart::text("reply")]).unwrap()),
            attachments: "[]".into(),
            model: "m".into(),
            client_message_id: None,
            created_at: "now".into(),
            turn_id: 1,
            seq: 2,
            content_length: 5,
            parts_length: Some(0),
        };
        assert!(build_send_reply(std::slice::from_ref(&user)).is_none());
        assert!(build_send_reply(&[assistant.clone(), user.clone()]).is_none());

        let response = build_send_reply(&[user, assistant]).unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
    }

    #[tokio::test]
    async fn build_send_reply_body_contains_roles_and_reply() {
        let user = MessageRow {
            id: 1,
            thread_id: "t1".into(),
            role: "user".into(),
            content: "hello".into(),
            thinking: None,
            parts: Some(serde_json::to_string(&[MessagePart::text("hello")]).unwrap()),
            attachments: "[]".into(),
            model: "m".into(),
            client_message_id: None,
            created_at: "now".into(),
            turn_id: 1,
            seq: 1,
            content_length: 5,
            parts_length: Some(0),
        };
        let assistant = MessageRow {
            id: 2,
            thread_id: "t1".into(),
            role: "assistant".into(),
            content: "reply".into(),
            thinking: Some("thinking".into()),
            parts: Some(serde_json::to_string(&[MessagePart::text("reply")]).unwrap()),
            attachments: "[]".into(),
            model: "m".into(),
            client_message_id: None,
            created_at: "now".into(),
            turn_id: 1,
            seq: 2,
            content_length: 5,
            parts_length: Some(0),
        };
        let response = build_send_reply(&[user, assistant]).unwrap();
        let body = to_bytes(response.into_body(), 4096).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["user_message"]["role"], "user");
        assert_eq!(json["assistant_message"]["role"], "assistant");
        assert_eq!(json["reply"], "reply");
        assert_eq!(json["thinking"], "thinking");
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
