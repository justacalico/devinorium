//! Interactive permission and ask callbacks.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
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

static REQUEST_NONCE: AtomicU64 = AtomicU64::new(1);

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
                let key = (thread_id.clone(), req.request_id.clone());
                let nonce = REQUEST_NONCE.fetch_add(1, Ordering::SeqCst);
                {
                    let mut map = state.pending_permission_requests.lock().await;
                    // A provider-chosen id may repeat; the newcomer cancels
                    // rather than evicting the prompt already on screen.
                    // An entry whose waiter already went away is a zombie,
                    // so the newcomer takes its slot instead.
                    match map.get(&key) {
                        Some(p) if !p.sender.is_closed() => return PermissionOutcome::Cancel,
                        Some(_) => {
                            map.remove(&key);
                        }
                        None => {}
                    }
                    map.insert(
                        key.clone(),
                        PendingPermissionRequest {
                            user_id,
                            nonce,
                            sender: response_tx,
                        },
                    );
                }
                // Arm cleanup only after the entry exists, so a duplicate
                // request id cannot drop the incumbent's prompt.
                let _cleanup = RemoveOnDrop::new(state.clone(), run.clone(), key, nonce);

                run.set_permission_request(Some(req.clone()));
                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        run.clear_permission_request(&req.request_id);
                        return PermissionOutcome::Cancel;
                    }
                };
                run.emit("permission_request", &payload);

                // Long timeout so users can disconnect, reload, and still
                // respond to permission requests for multi-day runs.
                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.clear_permission_request(&req.request_id);

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
    key: (String, String),
    nonce: u64,
}

impl RemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, key: (String, String), nonce: u64) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            key,
            nonce,
        }
    }
}

/// Remove `key` only while the stored entry is still the one the guard
/// was armed for; a newer entry under the same key must survive.
async fn remove_stale<K, V>(
    map: &tokio::sync::Mutex<HashMap<K, V>>,
    key: K,
    current: impl Fn(&V) -> bool,
) where
    K: Eq + std::hash::Hash,
{
    let mut map = map.lock().await;
    if map.get(&key).is_some_and(current) {
        map.remove(&key);
    }
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            if tokio::runtime::Handle::try_current().is_ok() {
                let key = self.key.clone();
                let nonce = self.nonce;
                tokio::spawn(async move {
                    remove_stale(&state.pending_permission_requests, key, |p| {
                        p.nonce == nonce
                    })
                    .await;
                });
            }
        }
        if let Some(run) = self.run.take() {
            run.clear_permission_request(&self.key.1);
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

    let key = (thread_id, request_id);
    let sender = {
        let mut map = state.pending_permission_requests.lock().await;
        if map.get(&key).is_some_and(|p| p.user_id == user.id) {
            map.remove(&key)
        } else {
            None
        }
    };

    match sender {
        Some(pending) => {
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
                let key = (thread_id.clone(), req.request_id.clone());
                let nonce = REQUEST_NONCE.fetch_add(1, Ordering::SeqCst);
                {
                    let mut map = state.pending_ask_requests.lock().await;
                    if let Some(p) = map.get(&key) {
                        if !p.sender.is_closed() {
                            return AskOutcome::Cancel;
                        }
                        map.remove(&key);
                    }
                    map.insert(
                        key.clone(),
                        PendingAskRequest {
                            user_id,
                            nonce,
                            sender: response_tx,
                        },
                    );
                }
                let _cleanup = AskRemoveOnDrop::new(state.clone(), run.clone(), key, nonce);

                let payload = match serde_json::to_string(&req) {
                    Ok(json) => json,
                    Err(_) => {
                        return AskOutcome::Cancel;
                    }
                };
                run.set_ask_request(Some(req.clone()));
                run.emit("ask_request", &payload);

                let result =
                    tokio::time::timeout(Duration::from_secs(7 * 24 * 60 * 60), response_rx).await;

                run.clear_ask_request(&req.request_id);

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
    key: (String, String),
    nonce: u64,
}

impl AskRemoveOnDrop {
    fn new(state: AppState, run: Arc<RunState>, key: (String, String), nonce: u64) -> Self {
        Self {
            state: Some(state),
            run: Some(run),
            key,
            nonce,
        }
    }
}

impl Drop for AskRemoveOnDrop {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            if tokio::runtime::Handle::try_current().is_ok() {
                let key = self.key.clone();
                let nonce = self.nonce;
                tokio::spawn(async move {
                    remove_stale(&state.pending_ask_requests, key, |p| p.nonce == nonce).await;
                });
            }
        }
        if let Some(run) = self.run.take() {
            run.clear_ask_request(&self.key.1);
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

    let key = (thread_id, request_id);
    let sender = {
        let mut map = state.pending_ask_requests.lock().await;
        if map.get(&key).is_some_and(|p| p.user_id == user.id) {
            map.remove(&key)
        } else {
            None
        }
    };

    match sender {
        Some(pending) => match pending.sender.send(body.answers) {
            Ok(()) => StatusCode::OK,
            Err(_) => StatusCode::GONE,
        },
        _ => StatusCode::NOT_FOUND,
    }
}

#[cfg(test)]
mod tests {
    use super::{remove_stale, AskResponseBody, PermissionResponseBody};
    use crate::PendingPermissionRequest;
    use std::collections::HashMap;

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

    #[tokio::test]
    async fn stale_cleanup_only_removes_matching_nonce() {
        let map = tokio::sync::Mutex::new(HashMap::new());
        let key = ("t".to_string(), "r".to_string());
        let (tx, _rx) = tokio::sync::oneshot::channel::<String>();
        map.lock().await.insert(
            key.clone(),
            PendingPermissionRequest {
                user_id: 1,
                nonce: 2,
                sender: tx,
            },
        );

        remove_stale(&map, key.clone(), |p| p.nonce == 1).await;
        assert!(map.lock().await.contains_key(&key));
        remove_stale(&map, key.clone(), |p| p.nonce == 2).await;
        assert!(map.lock().await.is_empty());
    }
}
