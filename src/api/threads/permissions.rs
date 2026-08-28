//! Interactive permission and ask callbacks.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;

use crate::auth::session::CurrentUser;
use crate::providers::{
    AskCallback, AskOutcome, AskRequest, PermissionCallback, PermissionOutcome, PermissionRequest,
};
use crate::thread_runner::RunState;
use crate::{AppState, PendingAskRequest, PendingPermissionRequest};

pub(crate) fn build_permission_callback(
    state: AppState,
    user_id: i64,
    thread_id: String,
    run: Arc<RunState>,
) -> PermissionCallback {
    Arc::new(
        move |req: PermissionRequest| -> Pin<Box<dyn Future<Output = PermissionOutcome> + Send>> {
            let state = state.clone();
            let run = run.clone();
            let thread_id = thread_id.clone();
            Box::pin(async move {
                let (response_tx, response_rx) = tokio::sync::oneshot::channel::<String>();
                let _cleanup = RemoveOnDrop::new(state.clone(), run.clone(), req.request_id.clone());

                {
                    let mut map = state.pending_permission_requests.lock().await;
                    map.insert(
                        req.request_id.clone(),
                        PendingPermissionRequest {
                            user_id,
                            thread_id,
                            sender: response_tx,
                        },
                    );
                }

                run.set_permission_request(Some(req.clone()));
                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        run.set_permission_request(None);
                        return PermissionOutcome::Cancel;
                    }
                };
                run.emit("permission_request", &payload);

                // Long timeout so users can disconnect, reload, and still
                // respond to permission requests for multi-day runs.
                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.set_permission_request(None);

                match result {
                    Ok(Ok(option_id)) if !option_id.is_empty() => {
                        PermissionOutcome::Allow { option_id }
                    }
                    _ => PermissionOutcome::Cancel,
                }
            })
        },
    ) as PermissionCallback
}

/// Removes a pending permission request from the map and the run snapshot
/// when the callback future is dropped (e.g. cancelled or the connection
/// closes), preventing memory leaks and abandoned senders.
struct RemoveOnDrop {
    state: Option<AppState>,
    run: Option<Arc<RunState>>,
    request_id: String,
}

impl RemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, request_id: String) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            request_id,
        }
    }
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            let request_id = self.request_id.clone();
            tokio::spawn(async move {
                let _ = state
                    .pending_permission_requests
                    .lock()
                    .await
                    .remove(&request_id);
            });
        }
        if let Some(run) = self.run.take() {
            if let Ok(guard) = run.permission_request.lock() {
                if guard
                    .as_ref()
                    .is_some_and(|r| r.request_id == self.request_id)
                {
                    drop(guard);
                    run.set_permission_request(None);
                }
            }
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct PermissionResponseBody {
    option_id: Option<String>,
}

pub(super) async fn respond_permission(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, request_id)): Path<(String, String)>,
    Json(body): Json<PermissionResponseBody>,
) -> impl IntoResponse {
    // Verify the user still owns the thread before accepting a response.
    if !matches!(state.db.get_thread(&thread_id, user.id).await, Ok(Some(_))) {
        return StatusCode::NOT_FOUND;
    }

    let sender = {
        let mut map = state.pending_permission_requests.lock().await;
        map.remove(&request_id)
    };

    match sender {
        Some(pending) if pending.user_id == user.id && pending.thread_id == thread_id => {
            if let Some(option_id) = body.option_id {
                match pending.sender.send(option_id) {
                    Ok(()) => StatusCode::OK,
                    Err(_) => StatusCode::GONE,
                }
            } else {
                // Drop the sender without responding, which signals cancellation
                // to the waiting provider.
                StatusCode::OK
            }
        }
        _ => StatusCode::NOT_FOUND,
    }
}

pub(crate) fn build_ask_callback(
    state: AppState,
    user_id: i64,
    thread_id: String,
    run: Arc<RunState>,
) -> AskCallback {
    Arc::new(
        move |req: AskRequest| -> Pin<Box<dyn Future<Output = AskOutcome> + Send>> {
            let state = state.clone();
            let run = run.clone();
            let thread_id = thread_id.clone();
            Box::pin(async move {
                let (response_tx, response_rx) =
                    tokio::sync::oneshot::channel::<Option<HashMap<String, serde_json::Value>>>();
                let _cleanup =
                    AskRemoveOnDrop::new(state.clone(), run.clone(), req.request_id.clone());

                {
                    let mut map = state.pending_ask_requests.lock().await;
                    map.insert(
                        req.request_id.clone(),
                        PendingAskRequest {
                            user_id,
                            thread_id,
                            sender: response_tx,
                        },
                    );
                }

                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        return AskOutcome::Cancel;
                    }
                };
                run.set_ask_request(Some(req));
                run.emit("ask_request", &payload);

                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.set_ask_request(None);

                match result {
                    Ok(Ok(Some(answers))) => AskOutcome::Answers(answers),
                    _ => AskOutcome::Cancel,
                }
            })
        },
    ) as AskCallback
}

struct AskRemoveOnDrop {
    state: Option<AppState>,
    run: Option<Arc<RunState>>,
    request_id: String,
}

impl AskRemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, request_id: String) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            request_id,
        }
    }
}

impl Drop for AskRemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            let request_id = self.request_id.clone();
            tokio::spawn(async move {
                let _ = state.pending_ask_requests.lock().await.remove(&request_id);
            });
        }
        if let Some(run) = self.run.take() {
            if let Ok(guard) = run.ask_request.lock() {
                if guard.as_ref().is_some_and(|r| r.request_id == self.request_id) {
                    drop(guard);
                    run.set_ask_request(None);
                }
            }
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct AskResponseBody {
    answers: Option<HashMap<String, serde_json::Value>>,
}

pub(super) async fn respond_ask(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path((thread_id, request_id)): Path<(String, String)>,
    Json(body): Json<AskResponseBody>,
) -> impl IntoResponse {
    if !matches!(state.db.get_thread(&thread_id, user.id).await, Ok(Some(_))) {
        return StatusCode::NOT_FOUND;
    }

    let sender = {
        let mut map = state.pending_ask_requests.lock().await;
        map.remove(&request_id)
    };

    match sender {
        Some(pending) if pending.user_id == user.id && pending.thread_id == thread_id => {
            match pending.sender.send(body.answers) {
                Ok(()) => StatusCode::OK,
                Err(_) => StatusCode::GONE,
            }
        }
        _ => StatusCode::NOT_FOUND,
    }
}

#[cfg(test)]
mod tests {
    use super::{AskResponseBody, PermissionResponseBody};

    #[test]
    fn permission_response_body_deserializes_option_id() {
        let with_id: PermissionResponseBody =
            serde_json::from_str(r#"{"option_id":"opt-1"}"#).unwrap();
        assert_eq!(with_id.option_id, Some("opt-1".into()));

        let without: PermissionResponseBody = serde_json::from_str("{}").unwrap();
        assert_eq!(without.option_id, None);
    }

    #[test]
    fn ask_response_body_deserializes_answers() {
        let with_answers: AskResponseBody =
            serde_json::from_str(r#"{"answers":{"name":"x"}}"#).unwrap();
        assert_eq!(with_answers.answers.as_ref().unwrap()["name"], "x");

        let without: AskResponseBody = serde_json::from_str("{}").unwrap();
        assert!(without.answers.is_none());
    }
}
