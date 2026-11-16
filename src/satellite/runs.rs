//! Satellite run endpoints: provider execution with streamed events.
//!
//! `POST /api/node/run` takes a fully-resolved provider request and answers
//! with an SSE stream of [`NodeEvent`]s. Interactive requests (permission
//! prompts, ask forms) pause the provider behind a oneshot the hub resolves
//! through `POST /api/node/callback`. `POST /api/node/runs/:id/cancel` flips
//! the run's cancel flag so the agent stops gracefully and keeps its
//! session context.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
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
    let buffered = Arc::new(AtomicUsize::new(0));
    let pending_ids: Arc<StdMutex<Vec<String>>> = Arc::new(StdMutex::new(Vec::new()));

    let task = {
        let state = state.clone();
        let tx = tx.clone();
        let cancel = cancel.clone();
        let buffered = buffered.clone();
        let pending_ids = pending_ids.clone();
        tokio::spawn(async move {
            drive(state, req, provider, tx, cancel, buffered, pending_ids).await;
        })
    };

    let stream = RunEventStream {
        rx: tokio_stream::wrappers::UnboundedReceiverStream::new(rx),
        buffered,
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

/// Events buffered for a client that reads slower than the provider
/// emits. Past this point the run is cancelled rather than letting a
/// drip-fed consumer grow satellite memory without bound.
const RUN_EVENT_BUFFER_CAP: usize = 1024;

/// Convert the wire options into provider-facing [`SendOptions`], wiring the
/// interactive callbacks through the event channel.
fn send_options(
    state: &Arc<SatelliteState>,
    tx: &mpsc::UnboundedSender<NodeEvent>,
    run_id: &str,
    cancel: Arc<AtomicBool>,
    buffered: Arc<AtomicUsize>,
    pending_ids: Arc<StdMutex<Vec<String>>>,
    wire: crate::node::WireSendOptions,
) -> anyhow::Result<SendOptions> {
    let part_callback: PartCallback = {
        let tx = tx.clone();
        let stalled = cancel.clone();
        Arc::new(move |ev: PartEvent| {
            // Part events are the flood source; the stream decrements this
            // counter as it drains them.
            if buffered.fetch_add(1, Ordering::SeqCst) >= RUN_EVENT_BUFFER_CAP {
                buffered.fetch_sub(1, Ordering::SeqCst);
                stalled.store(true, Ordering::SeqCst);
                return;
            }
            if tx
                .send(NodeEvent::Part {
                    part: ev.part().clone(),
                    update: ev.is_update(),
                })
                .is_err()
            {
                buffered.fetch_sub(1, Ordering::SeqCst);
            }
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
        let run_id = run_id.to_string();
        Arc::new(move |request: crate::providers::PermissionRequest| {
            let tx = tx.clone();
            let state = state.clone();
            let pending_ids = pending_ids.clone();
            let run_id = run_id.clone();
            Box::pin(async move {
                // Provider-chosen ids repeat across runs; namespace by run
                // so two runs cannot evict or answer each other's prompt.
                // The hub echoes this id back verbatim in the callback.
                let request_id = format!("{run_id}/{}", request.request_id);
                let (otx, orx) = oneshot::channel();
                {
                    let mut pending = state.pending.lock().await;
                    // Same rule as the hub: a repeated id inside one run
                    // cancels the newcomer rather than evicting the prompt
                    // already on screen.
                    if pending.contains_key(&request_id) {
                        return PermissionOutcome::Cancel;
                    }
                    pending.insert(request_id.clone(), PendingCallback::Permission(otx));
                }
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
        let run_id = run_id.to_string();
        Arc::new(move |request: crate::providers::AskRequest| {
            let tx = tx.clone();
            let state = state.clone();
            let pending_ids = pending_ids.clone();
            let run_id = run_id.clone();
            Box::pin(async move {
                let request_id = format!("{run_id}/{}", request.request_id);
                let (otx, orx) = oneshot::channel();
                {
                    let mut pending = state.pending.lock().await;
                    if pending.contains_key(&request_id) {
                        return AskOutcome::Cancel;
                    }
                    pending.insert(request_id.clone(), PendingCallback::Ask(otx));
                }
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
        browser_feed_token: None,
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
    buffered: Arc<AtomicUsize>,
    pending_ids: Arc<StdMutex<Vec<String>>>,
) {
    let mut wire = req.options;
    // A hub-minted browser feed token means this run may stream its agent
    // browser back: register it and point the builtin server at this node's
    // own ingest endpoint, since the browser spawns here, not on the hub.
    if let Some(token) = req.browser_feed_token.as_deref().filter(|t| !t.is_empty()) {
        state.register_browser_feed(token).await;
        crate::mcp::attach_browser_feed(&mut wire.mcp_servers, &state.browser_feed_url(), token);
    }
    let working_dir = wire.working_dir.clone();
    // Hooks and plugin MCP merge are owner-trust features; the hub sends
    // the flag so the satellite applies the same gate it cannot see.
    let owner_plugins = wire.owner_plugins;
    let mut prompt = req.prompt;
    // Non-Devin providers expand every skill inline; Devin resolves its
    // own skills natively, so only plugin-provided commands expand for it.
    if wire.expand_skills {
        prompt = crate::skills::expand_skill_prompt(&prompt, &working_dir, &state.home_dir).await;
    } else {
        prompt = crate::skills::expand_plugin_prompt(&prompt, &working_dir, &state.home_dir).await;
    }

    // The satellite's plugins live on its filesystem, so its hooks fire
    // here - mirroring what the hub does for local owner runs.
    if owner_plugins {
        let outcome = crate::plugins::run_hooks(
            &state.home_dir,
            crate::plugins::EVENT_PROMPT_SUBMIT,
            &working_dir,
            serde_json::json!({
                "session_id": req.session_id.as_deref().unwrap_or(""),
                "run_id": req.run_id,
                "prompt": prompt,
            }),
        )
        .await;
        if let Some(reason) = outcome.block {
            let _ = tx.send(NodeEvent::Error {
                message: format!("prompt blocked by plugin hook: {reason}"),
            });
            return;
        }
        crate::plugins::append_context(&mut prompt, &outcome.context);
        if req.session_id.is_none() {
            let outcome = crate::plugins::run_hooks(
                &state.home_dir,
                crate::plugins::EVENT_SESSION_START,
                &working_dir,
                serde_json::json!({ "run_id": req.run_id }),
            )
            .await;
            crate::plugins::append_context(&mut prompt, &outcome.context);
        }
        crate::plugins::merge_plugin_mcp(&state.home_dir, &mut wire.mcp_servers).await;
    }
    let session_id = req.session_id.clone();
    let result_prompt_dir = working_dir.clone();
    let result_run_id = req.run_id.clone();
    let options = match send_options(
        &state,
        &tx,
        &req.run_id,
        cancel,
        buffered,
        pending_ids,
        wire,
    ) {
        Ok(o) => o,
        Err(e) => {
            let _ = tx.send(NodeEvent::Error {
                message: format!("invalid request: {e}"),
            });
            return;
        }
    };

    let result = match &session_id {
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

    if owner_plugins {
        let stop_session = result
            .as_ref()
            .ok()
            .and_then(|o| o.session_id.as_deref())
            .or(session_id.as_deref())
            .unwrap_or("");
        let _ = crate::plugins::run_hooks(
            &state.home_dir,
            crate::plugins::EVENT_STOP,
            &result_prompt_dir,
            serde_json::json!({
                "session_id": stop_session,
                "run_id": result_run_id,
                "stop_hook_active": false,
            }),
        )
        .await;
    }

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
    buffered: Arc<AtomicUsize>,
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
                if matches!(ev, NodeEvent::Part { .. }) {
                    self.buffered.fetch_sub(1, Ordering::SeqCst);
                }
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
    // Provider-supplied ids are stored verbatim, so the lookup must not
    // trim either or an id with whitespace could never be answered.
    let pending = state.pending.lock().await.remove(&req.request_id);
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
