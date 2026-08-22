//! Background thread runner.
//!
//! A thread run is a single provider invocation that outlives any one HTTP
//! connection. Runs broadcast events to any connected listeners, so a client
//! can disconnect, reload, and resubscribe without interrupting the backend.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, Mutex, RwLock};
use tokio::task::AbortHandle;
use uuid::Uuid;

use crate::providers::{collect_text, collect_thinking, AskRequest, MessagePart, PermissionRequest};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunEvent {
    pub event: String,
    pub data: String,
    pub seq: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Idle,
    Running,
    Completed,
    Failed,
    Stopped,
}

impl std::fmt::Display for RunStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunStatus::Idle => write!(f, "idle"),
            RunStatus::Running => write!(f, "running"),
            RunStatus::Completed => write!(f, "completed"),
            RunStatus::Failed => write!(f, "failed"),
            RunStatus::Stopped => write!(f, "stopped"),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RunSnapshot {
    pub run_id: String,
    pub thread_id: String,
    pub status: RunStatus,
    pub started_at: String,
    pub updated_at: String,
    pub error: Option<String>,
    pub text: String,
    pub thinking: String,
    pub thinking_active: bool,
    pub parts: Vec<MessagePart>,
    pub tool_calls: Vec<MessagePart>,
    pub permission_request: Option<PermissionRequest>,
    pub ask_request: Option<AskRequest>,
    pub last_seq: u64,
}

/// Shared state for a single run.
pub struct RunState {
    pub run_id: String,
    pub thread_id: String,
    events: std::sync::Mutex<Option<broadcast::Sender<RunEvent>>>,
    initial_receiver: std::sync::Mutex<Option<broadcast::Receiver<RunEvent>>>,
    next_seq: std::sync::atomic::AtomicU64,
    pub status: RwLock<RunStatus>,
    pub error: RwLock<Option<String>>,
    pub started_at: String,
    pub updated_at: RwLock<String>,
    pub abort: std::sync::Mutex<Option<AbortHandle>>,
    pub cancelled: Arc<AtomicBool>,
    pub parts: std::sync::Mutex<Vec<MessagePart>>,
    pub permission_request: std::sync::Mutex<Option<PermissionRequest>>,
    pub ask_request: std::sync::Mutex<Option<AskRequest>>,
}

impl RunState {
    /// Add or replace a streamed part. Tool-call parts are replaced by id so
    /// updates (progress, output) keep the same slot; text and thinking parts
    /// are appended. Updates for non-tool parts are ignored because they have
    /// no stable identity.
    pub fn apply_part(&self, part: MessagePart, is_update: bool) {
        let mut parts = self
            .parts
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(tool_id) = part.tool_id() {
            if let Some(idx) = parts.iter().position(|p| p.tool_id() == Some(tool_id)) {
                parts[idx] = part;
                return;
            }
        }
        if is_update {
            return;
        }
        parts.push(part);
    }

    pub fn set_permission_request(&self, req: Option<PermissionRequest>) {
        if let Ok(mut guard) = self.permission_request.lock() {
            *guard = req;
        }
    }

    pub fn set_ask_request(&self, req: Option<AskRequest>) {
        if let Ok(mut guard) = self.ask_request.lock() {
            *guard = req;
        }
    }

    /// Emit an event to all current listeners. Returns the number of receivers.
    pub fn emit(&self, event: &str, data: &str) -> usize {
        let seq = self.next_seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let Ok(guard) = self.events.lock() else {
            return 0;
        };
        if let Some(sender) = guard.as_ref() {
            sender
                .send(RunEvent {
                    event: event.to_string(),
                    data: data.to_string(),
                    seq,
                })
                .unwrap_or_default()
        } else {
            0
        }
    }

    /// Create a new event receiver, or `None` if the sender has closed.
    /// The first subscriber receives the initial receiver created with the
    /// sender, so events emitted between run start and the first subscription
    /// are not dropped.
    pub fn subscribe(&self) -> Option<broadcast::Receiver<RunEvent>> {
        if let Ok(mut guard) = self.initial_receiver.lock() {
            if let Some(rx) = guard.take() {
                return Some(rx);
            }
        }
        self.events.lock().ok().and_then(|g| g.as_ref().map(|s| s.subscribe()))
    }

    /// Close the event sender so SSE streams end.
    pub fn close(&self) {
        if let Ok(mut guard) = self.events.lock() {
            guard.take();
        }
        if let Ok(mut guard) = self.initial_receiver.lock() {
            guard.take();
        }
    }

    pub async fn set_status(&self, status: RunStatus) {
        let mut guard = self.status.write().await;
        if status != RunStatus::Stopped && self.cancelled.load(Ordering::SeqCst) {
            return;
        }
        *guard = status;
        let now = chrono::Utc::now().to_rfc3339();
        *self.updated_at.write().await = now;
    }

    pub async fn set_error(&self, error: String) {
        if self.cancelled.load(Ordering::SeqCst) {
            return;
        }
        *self.error.write().await = Some(error);
    }

    pub async fn snapshot(&self) -> RunSnapshot {
        let parts = self
            .parts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let permission_request = self
            .permission_request
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let ask_request = self
            .ask_request
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let text = collect_text(&parts);
        let thinking = collect_thinking(&parts);
        let thinking_active = matches!(parts.last(), Some(MessagePart::Thinking { .. }));
        let tool_calls = parts
            .iter()
            .filter(|p| matches!(p, MessagePart::ToolCall { .. }))
            .cloned()
            .collect();

        let last_seq = self.next_seq.load(std::sync::atomic::Ordering::SeqCst);

        RunSnapshot {
            run_id: self.run_id.clone(),
            thread_id: self.thread_id.clone(),
            status: *self.status.read().await,
            started_at: self.started_at.clone(),
            updated_at: self.updated_at.read().await.clone(),
            error: self.error.read().await.clone(),
            text,
            thinking,
            thinking_active,
            parts,
            tool_calls,
            permission_request,
            ask_request,
            last_seq,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartError {
    AlreadyRunning,
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::AlreadyRunning => write!(f, "thread already has an active run"),
        }
    }
}

/// Manages background runs keyed by thread id.
#[derive(Clone)]
pub struct ThreadRunner {
    runs: Arc<Mutex<HashMap<String, Arc<RunState>>>>,
}

impl Default for ThreadRunner {
    fn default() -> Self {
        Self::new()
    }
}

impl ThreadRunner {
    pub fn new() -> Self {
        Self {
            runs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn get(&self, thread_id: &str) -> Option<Arc<RunState>> {
        self.runs.lock().await.get(thread_id).cloned()
    }

    pub async fn subscribe(&self, thread_id: &str) -> Option<broadcast::Receiver<RunEvent>> {
        self.runs.lock().await.get(thread_id)?.subscribe()
    }

    /// Return the thread ids of every run whose status is currently `Running`.
    pub async fn running_ids(&self) -> Vec<String> {
        let runs = self.runs.lock().await;
        let mut ids = Vec::new();
        for (id, run) in runs.iter() {
            if *run.status.read().await == RunStatus::Running {
                ids.push(id.clone());
            }
        }
        ids
    }

    /// Start a new background run for `thread_id`. If a run is already active,
    /// returns `AlreadyRunning`.
    pub async fn start<F, Fut>(&self, thread_id: String, f: F) -> Result<Arc<RunState>, StartError>
    where
        F: FnOnce(Arc<RunState>) -> Fut + Send + 'static,
        Fut: Future<Output = Result<()>> + Send + 'static,
    {
        let mut runs = self.runs.lock().await;

        if let Some(existing) = runs.get(&thread_id) {
            let status = *existing.status.read().await;
            if status == RunStatus::Running {
                return Err(StartError::AlreadyRunning);
            }
        }

        let (events, initial_rx) = broadcast::channel(256);
        let now = chrono::Utc::now().to_rfc3339();
        let state = Arc::new(RunState {
            run_id: Uuid::new_v4().to_string(),
            thread_id: thread_id.clone(),
            events: std::sync::Mutex::new(Some(events)),
            initial_receiver: std::sync::Mutex::new(Some(initial_rx)),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: now.clone(),
            updated_at: RwLock::new(now),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(AtomicBool::new(false)),
            parts: std::sync::Mutex::new(Vec::new()),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        });

        let state_for_task = state.clone();
        let state_for_cleanup = state.clone();
        let runs_for_cleanup = self.runs.clone();
        let thread_id_for_cleanup = thread_id.clone();
        let handle = tokio::spawn(async move {
            let result = f(state_for_task.clone()).await;
            if !state_for_task.cancelled.load(Ordering::SeqCst) {
                match result {
                    Ok(()) => {
                        let _ = state_for_task.set_status(RunStatus::Completed).await;
                    }
                    Err(e) => {
                        let _ = state_for_task.set_status(RunStatus::Failed).await;
                        let _ = state_for_task.set_error(e.to_string()).await;
                        state_for_task.emit("error", &e.to_string());
                    }
                }
            }
            // Close the broadcast so in-flight SSE streams end, but keep the
            // run record around long enough for clients to reconnect and see
            // the final snapshot after a long run.
            state_for_task.close();
            tokio::time::sleep(std::time::Duration::from_secs(120)).await;
            let mut runs = runs_for_cleanup.lock().await;
            if let Some(current) = runs.get(&thread_id_for_cleanup) {
                if Arc::ptr_eq(current, &state_for_cleanup) {
                    runs.remove(&thread_id_for_cleanup);
                }
            }
        });

        *state.abort.lock().unwrap() = Some(handle.abort_handle());
        runs.insert(thread_id, state.clone());
        Ok(state)
    }

    /// Stop an active run for `thread_id`. Returns the final snapshot if a run
    /// was stopped, or the current snapshot if it already finished or failed.
    pub async fn stop(&self, thread_id: &str) -> Option<RunSnapshot> {
        let runs = self.runs.lock().await;
        let run = runs.get(thread_id).cloned()?;
        let status = *run.status.read().await;

        if status != RunStatus::Running {
            drop(runs);
            return Some(run.snapshot().await);
        }

        // Set the cancelled flag so the provider can cancel the in-flight
        // prompt gracefully via ACP $/cancelRequest. This lets the agent
        // session preserve its context for subsequent messages.
        run.cancelled.store(true, Ordering::SeqCst);
        let _ = run.set_status(RunStatus::Stopped).await;
        run.emit("stopped", r#"{"status":"stopped"}"#);
        run.close();

        // Hard-abort the task after a grace period in case the agent
        // doesn't respond to cancellation.
        let abort_handle = run.abort.lock().unwrap().take();
        let state = run.clone();
        let runs_for_cleanup = self.runs.clone();
        let id = thread_id.to_string();
        tokio::spawn(async move {
            // Give the provider 10s to finish graceful cancellation.
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
            if let Some(handle) = abort_handle {
                handle.abort();
            }
            tokio::time::sleep(std::time::Duration::from_secs(110)).await;
            let mut map = runs_for_cleanup.lock().await;
            if let Some(r) = map.get(&id) {
                if Arc::ptr_eq(r, &state) {
                    map.remove(&id);
                }
            }
        });

        drop(runs);
        Some(run.snapshot().await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{AskQuestion, AskRequest, MessagePart, ToolCallEvent};

    #[tokio::test]
    async fn run_state_accumulates_text_and_thinking_for_snapshot() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![
                MessagePart::text("Hello "),
                MessagePart::thinking("hmm"),
                MessagePart::text("world"),
            ]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        };

        state.apply_part(
            MessagePart::tool_call(ToolCallEvent {
                id: "tc-1".into(),
                title: "Read".into(),
                kind: "read".into(),
                status: "completed".into(),
                command: None,
                output: None,
                output_preview: None,
                changed_files: vec![],
                diffs: vec![],
            }),
            false,
        );

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.text, "Hello world");
        assert_eq!(snapshot.thinking, "hmm");
        assert!(!snapshot.thinking_active);
        assert_eq!(snapshot.tool_calls.len(), 1);
        assert_eq!(snapshot.parts.len(), 4);
    }

    #[tokio::test]
    async fn run_state_replaces_tool_call_by_id() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        };

        state.apply_part(
            MessagePart::tool_call(ToolCallEvent {
                id: "tc-1".into(),
                title: "Read".into(),
                kind: "read".into(),
                status: "in_progress".into(),
                command: None,
                output: None,
                output_preview: None,
                changed_files: vec![],
                diffs: vec![],
            }),
            false,
        );
        state.apply_part(
            MessagePart::tool_call(ToolCallEvent {
                id: "tc-1".into(),
                title: "Read".into(),
                kind: "read".into(),
                status: "completed".into(),
                command: Some("cat file".into()),
                output: Some("hello".into()),
                output_preview: None,
                changed_files: vec![],
                diffs: vec![],
            }),
            true,
        );

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.parts.len(), 1);
        assert_eq!(snapshot.tool_calls.len(), 1);
    }

    #[tokio::test]
    async fn run_state_does_not_append_text_update() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![
                MessagePart::text("first "),
            ]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        };

        state.apply_part(MessagePart::text("second "), true);

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.text, "first ");
        assert_eq!(snapshot.parts.len(), 1);
    }

    #[tokio::test]
    async fn run_state_assigns_increasing_seq_numbers() {
        let (events, initial_rx) = broadcast::channel(8);
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(Some(events)),
            initial_receiver: std::sync::Mutex::new(Some(initial_rx)),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        };

        let mut rx = state.subscribe().unwrap();
        state.emit("part", "a");
        state.emit("part", "b");

        assert_eq!(rx.recv().await.unwrap().seq, 1);
        assert_eq!(rx.recv().await.unwrap().seq, 2);

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.last_seq, 2);
    }

    #[tokio::test]
    async fn run_state_set_ask_request_updates_snapshot() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
        };

        let ask = AskRequest {
            request_id: "a1".into(),
            message: "Need input".into(),
            questions: vec![AskQuestion {
                id: "q1".into(),
                prompt: "Value".into(),
                description: None,
                field_type: "text".into(),
                options: vec![],
                required: true,
            }],
        };

        state.set_ask_request(Some(ask.clone()));
        let snapshot = state.snapshot().await;
        assert!(snapshot.ask_request.is_some());
        assert_eq!(snapshot.ask_request.as_ref().unwrap().request_id, "a1");

        state.set_ask_request(None);
        let snapshot = state.snapshot().await;
        assert!(snapshot.ask_request.is_none());
    }

    #[tokio::test]
    async fn running_ids_lists_only_active_runs() {
        let runner = ThreadRunner::new();
        let _ = runner
            .start("t1".into(), |_state| async {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                Ok(())
            })
            .await
            .unwrap();

        let ids = runner.running_ids().await;
        assert_eq!(ids, vec!["t1"]);

        runner.stop("t1").await;

        let ids = runner.running_ids().await;
        assert!(ids.is_empty());
    }
}
