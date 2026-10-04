//! Satellite run endpoints: provider execution with streamed events.
//!
//! `POST /api/node/run` takes a fully-resolved provider request and answers
//! with an SSE stream of [`NodeEvent`]s. Interactive requests (permission
//! prompts, ask forms) pause the provider behind a oneshot the hub resolves
//! through `POST /api/node/callback`. `POST /api/node/runs/:id/cancel` flips
//! the run's cancel flag so the agent stops gracefully and keeps its
//! session context.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::task::{Context, Poll};

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use futures::Stream;
use tokio::sync::{mpsc, oneshot};

use crate::node::{
    CallbackOutcome, CallbackRequest, NodeEvent, ProviderOpRequest, RunOutcome, RunRequest,
    SkillListRequest, WireAttachment,
};
use crate::providers::{
    AskCallback, AskOutcome, Attachment, PartCallback, PartEvent, PermissionCallback,
    PermissionOutcome, ProviderConfig, SendOptions, SendRequest, SessionCallback, StartRequest,
};
use crate::satellite::{bad_request, internal, NodeRun, PendingCallback, SatelliteState};

pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new()
        .route("/api/node/run", post(run))
        .route("/api/node/callback", post(callback))
        .route("/api/node/runs/:id/cancel", post(cancel_run))
        .route("/api/node/provider/models", post(models))
        .route("/api/node/provider/health", post(health))
        .route("/api/node/skills/list", post(skills_list))
}

const MAX_RUN_ID_LEN: usize = 64;

async fn run(State(state): State<Arc<SatelliteState>>, Json(req): Json<RunRequest>) -> Response {
    let run_id = req.run_id.trim().to_string();
    if run_id.is_empty()
        || run_id.len() > MAX_RUN_ID_LEN
        || !run_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return bad_request("invalid run_id");
    }

    let provider = match crate::providers::build_provider(ProviderConfig {
        id: req.provider.id.clone(),
        command: req.provider.command.clone(),
        default_model: req.provider.default_model.clone(),
    }) {
        Ok(p) => p,
        Err(e) => return bad_request(format!("unknown provider: {e}")),
    };

    let cancel = Arc::new(AtomicBool::new(false));
    {
        let mut runs = state.runs.lock().await;
        if runs.contains_key(&run_id) {
            return (
                StatusCode::CONFLICT,
                Json(crate::node::NodeError::new(
                    "conflict",
                    "run id already in use",
                )),
            )
                .into_response();
        }
        runs.insert(
            run_id.clone(),
            NodeRun {
                cancel: cancel.clone(),
            },
        );
    }

    let (tx, rx) = mpsc::unbounded_channel::<NodeEvent>();
    let pending_ids: Arc<StdMutex<Vec<String>>> = Arc::new(StdMutex::new(Vec::new()));

    let task = {
        let state = state.clone();
        let tx = tx.clone();
        let cancel = cancel.clone();
        let pending_ids = pending_ids.clone();
        tokio::spawn(async move {
            drive(state, req, provider, tx, cancel, pending_ids).await;
        })
    };

    let stream = RunEventStream {
        rx: tokio_stream::wrappers::UnboundedReceiverStream::new(rx),
        _guard: RunGuard {
            state,
            run_id: run_id.to_string(),
            task: task.abort_handle(),
            pending_ids,
        },
    };
    Sse::new(stream)
        .keep_alive(
            axum::response::sse::KeepAlive::new().interval(std::time::Duration::from_secs(15)),
        )
        .into_response()
}

/// Convert the wire options into provider-facing [`SendOptions`], wiring the
/// interactive callbacks through the event channel.
fn send_options(
    state: &Arc<SatelliteState>,
    tx: &mpsc::UnboundedSender<NodeEvent>,
    cancel: Arc<AtomicBool>,
    pending_ids: Arc<StdMutex<Vec<String>>>,
    wire: crate::node::WireSendOptions,
) -> anyhow::Result<SendOptions> {
    let part_callback: PartCallback = {
        let tx = tx.clone();
        Arc::new(move |ev: PartEvent| {
            let _ = tx.send(NodeEvent::Part {
                part: ev.part().clone(),
                update: ev.is_update(),
            });
        })
    };

    let session_callback: SessionCallback = {
        let tx = tx.clone();
        Arc::new(move |session_id: String| {
            let tx = tx.clone();
            Box::pin(async move {
                let _ = tx.send(NodeEvent::Session { session_id });
            })
        })
    };

    let permission_callback: PermissionCallback = {
        let tx = tx.clone();
        let state = state.clone();
        let pending_ids = pending_ids.clone();
        Arc::new(move |request: crate::providers::PermissionRequest| {
            let tx = tx.clone();
            let state = state.clone();
            let pending_ids = pending_ids.clone();
            Box::pin(async move {
                let request_id = request.request_id.clone();
                let (otx, orx) = oneshot::channel();
                state
                    .pending
                    .lock()
                    .await
                    .insert(request_id.clone(), PendingCallback::Permission(otx));
                if let Ok(mut ids) = pending_ids.lock() {
                    ids.push(request_id.clone());
                }
                if tx
                    .send(NodeEvent::Permission {
                        request_id,
                        request,
                    })
                    .is_err()
                {
                    return PermissionOutcome::Cancel;
                }
                orx.await.unwrap_or(PermissionOutcome::Cancel)
            })
        })
    };

    let ask_callback: AskCallback = {
        let tx = tx.clone();
        let state = state.clone();
        let pending_ids = pending_ids.clone();
        Arc::new(move |request: crate::providers::AskRequest| {
            let tx = tx.clone();
            let state = state.clone();
            let pending_ids = pending_ids.clone();
            Box::pin(async move {
                let request_id = request.request_id.clone();
                let (otx, orx) = oneshot::channel();
                state
                    .pending
                    .lock()
                    .await
                    .insert(request_id.clone(), PendingCallback::Ask(otx));
                if let Ok(mut ids) = pending_ids.lock() {
                    ids.push(request_id.clone());
                }
                if tx
                    .send(NodeEvent::Ask {
                        request_id,
                        request,
                    })
                    .is_err()
                {
                    return AskOutcome::Cancel;
                }
                orx.await.unwrap_or(AskOutcome::Cancel)
            })
        })
    };

    let mut attachments = Vec::with_capacity(wire.attachments.len());
    for a in &wire.attachments {
        let data = decode_attachment(a)?;
        attachments.push(Attachment {
            filename: a.filename.clone(),
            mime: a.mime.clone(),
            data,
        });
    }

    Ok(SendOptions {
        model: wire.model,
        reasoning_effort: wire.reasoning_effort,
        working_dir: wire.working_dir,
        permission_mode: wire.permission_mode,
        permissions: wire.permissions,
        attachments,
        permission_callback: Some(permission_callback),
        ask_callback: Some(ask_callback),
        part_callback: Some(part_callback),
        session_callback: Some(session_callback),
        interaction_mode: wire.interaction_mode,
        cancel_signal: Some(cancel),
        max_output_tokens: wire.max_output_tokens,
        mcp_servers: wire.mcp_servers,
    })
}

fn decode_attachment(a: &WireAttachment) -> anyhow::Result<Vec<u8>> {
    use base64::Engine;
    Ok(base64::engine::general_purpose::STANDARD.decode(&a.data_b64)?)
}

async fn drive(
    state: Arc<SatelliteState>,
    req: RunRequest,
    provider: Box<dyn crate::providers::Provider>,
    tx: mpsc::UnboundedSender<NodeEvent>,
    cancel: Arc<AtomicBool>,
    pending_ids: Arc<StdMutex<Vec<String>>>,
) {
    let mut prompt = req.prompt;
    if req.options.expand_skills {
        prompt =
            crate::skills::expand_skill_prompt(&prompt, &req.options.working_dir, &state.home_dir)
                .await;
    }
    let options = match send_options(&state, &tx, cancel, pending_ids, req.options) {
        Ok(o) => o,
        Err(e) => {
            let _ = tx.send(NodeEvent::Error {
                message: format!("invalid request: {e}"),
            });
            return;
        }
    };

    let result = match &req.session_id {
        Some(session_id) => provider
            .send(SendRequest {
                session_id: session_id.clone(),
                prompt,
                options,
            })
            .await
            .map(|r| RunOutcome {
                session_id: None,
                title: None,
                reply: r.reply,
                thinking: r.thinking,
                parts: r.parts,
                usage: r.usage,
            }),
        None => {
            let session_cb = options.session_callback.clone();
            provider
                .start(StartRequest { prompt, options })
                .await
                .map(move |r| {
                    // The session callback already streamed the id, but a
                    // provider that never fires it still reports it here.
                    let _ = session_cb;
                    RunOutcome {
                        session_id: Some(r.session_id),
                        title: Some(r.title),
                        reply: r.reply,
                        thinking: r.thinking,
                        parts: r.parts,
                        usage: r.usage,
                    }
                })
        }
    };

    match result {
        Ok(outcome) => {
            let _ = tx.send(NodeEvent::Done {
                outcome: Box::new(outcome),
            });
        }
        Err(e) => {
            let _ = tx.send(NodeEvent::Error {
                message: e.to_string(),
            });
        }
    }
}

/// The SSE body: yields each [`NodeEvent`] as a `node` event with the enum
/// serialized in `data`. Dropping it (client disconnect or end of stream)
/// cancels and unregisters the run.
struct RunEventStream {
    rx: tokio_stream::wrappers::UnboundedReceiverStream<NodeEvent>,
    _guard: RunGuard,
}

impl Stream for RunEventStream {
    type Item = Result<Event, std::convert::Infallible>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Self::Item>> {
        let ev = std::pin::Pin::new(&mut self.rx).poll_next(cx);
        match ev {
            Poll::Ready(Some(ev)) => {
                let json = serde_json::to_string(&ev).unwrap_or_else(|_| "{}".into());
                Poll::Ready(Some(Ok(Event::default().event("node").data(json))))
            }
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

/// Cleanup on stream end or disconnect: flip the cancel flag, drop the run
/// registration, abort the provider task and release its pending callbacks.
struct RunGuard {
    state: Arc<SatelliteState>,
    run_id: String,
    task: tokio::task::AbortHandle,
    pending_ids: Arc<StdMutex<Vec<String>>>,
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        let state = self.state.clone();
        let run_id = self.run_id.clone();
        let pending_ids = self.pending_ids.clone();
        self.task.abort();
        tokio::spawn(async move {
            if let Some(run) = state.runs.lock().await.remove(&run_id) {
                run.cancel.store(true, Ordering::SeqCst);
            }
            let ids: Vec<String> = pending_ids
                .lock()
                .map(|mut g| std::mem::take(&mut *g))
                .unwrap_or_default();
            if !ids.is_empty() {
                let mut pending = state.pending.lock().await;
                for id in ids {
                    pending.remove(&id);
                }
            }
        });
    }
}

/// Answer a pending permission or ask request.
async fn callback(
    State(state): State<Arc<SatelliteState>>,
    Json(req): Json<CallbackRequest>,
) -> Response {
    let request_id = req.request_id.trim().to_string();
    let pending = state.pending.lock().await.remove(&request_id);
    let Some(pending) = pending else {
        return (
            StatusCode::NOT_FOUND,
            Json(crate::node::NodeError::new(
                "not_found",
                "no pending request with that id",
            )),
        )
            .into_response();
    };

    let delivered = match (pending, req.outcome) {
        (PendingCallback::Permission(tx), CallbackOutcome::Permission { option_id }) => {
            tx.send(PermissionOutcome::Allow { option_id }).is_ok()
        }
        (PendingCallback::Permission(tx), CallbackOutcome::PermissionCancel) => {
            tx.send(PermissionOutcome::Cancel).is_ok()
        }
        (PendingCallback::Ask(tx), CallbackOutcome::Ask { answers }) => {
            tx.send(AskOutcome::Answers(answers)).is_ok()
        }
        (PendingCallback::Ask(tx), CallbackOutcome::AskCancel) => {
            tx.send(AskOutcome::Cancel).is_ok()
        }
        // Kind mismatch: the request id exists but the answer type is wrong.
        // The pending entry is already removed; the waiter sees a dropped
        // channel and cancels, which is the safe direction.
        _ => false,
    };

    if delivered {
        Json(serde_json::json!({"ok": true})).into_response()
    } else {
        (
            StatusCode::GONE,
            Json(crate::node::NodeError::new(
                "gone",
                "request is no longer pending",
            )),
        )
            .into_response()
    }
}

async fn cancel_run(
    State(state): State<Arc<SatelliteState>>,
    Path(run_id): Path<String>,
) -> Response {
    let runs = state.runs.lock().await;
    match runs.get(&run_id) {
        Some(run) => {
            run.cancel.store(true, Ordering::SeqCst);
            Json(serde_json::json!({"ok": true})).into_response()
        }
        None => (
            StatusCode::NOT_FOUND,
            Json(crate::node::NodeError::new("not_found", "no such run")),
        )
            .into_response(),
    }
}

async fn models(
    State(_state): State<Arc<SatelliteState>>,
    Json(req): Json<ProviderOpRequest>,
) -> Response {
    let provider = match crate::providers::build_provider(ProviderConfig {
        id: req.id,
        command: req.command,
        default_model: req.default_model,
    }) {
        Ok(p) => p,
        Err(e) => return bad_request(format!("unknown provider: {e}")),
    };
    match provider.list_models().await {
        Ok(models) => Json(models).into_response(),
        Err(e) => internal(e).into_response(),
    }
}

async fn health(
    State(_state): State<Arc<SatelliteState>>,
    Json(req): Json<ProviderOpRequest>,
) -> Response {
    let provider = match crate::providers::build_provider(ProviderConfig {
        id: req.id,
        command: req.command,
        default_model: req.default_model,
    }) {
        Ok(p) => p,
        Err(e) => return bad_request(format!("unknown provider: {e}")),
    };
    match provider.health_check().await {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            Json(crate::node::NodeError::new("unhealthy", e.to_string())),
        )
            .into_response(),
    }
}

async fn skills_list(
    State(state): State<Arc<SatelliteState>>,
    Json(req): Json<SkillListRequest>,
) -> Response {
    let skills = crate::skills::discover_skills(&req.working_dir, &state.home_dir).await;
    Json(serde_json::json!({
        "skills": skills.iter().map(|s| &s.info).collect::<Vec<_>>(),
    }))
    .into_response()
}
