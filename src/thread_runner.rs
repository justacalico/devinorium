//! Background thread runner.
//!
//! A thread run is a single provider invocation that outlives any one HTTP
//! connection. Runs broadcast events to any connected listeners, so a client
//! can disconnect, reload, and resubscribe without interrupting the backend.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, Mutex, RwLock};
use tokio::task::AbortHandle;
use uuid::Uuid;

use crate::providers::{collect_text, collect_thinking, MessagePart, PermissionRequest};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunEvent {
    pub event: String,
    pub data: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Idle,
    Running,
    Completed,
    Failed,
}

impl std::fmt::Display for RunStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunStatus::Idle => write!(f, "idle"),
            RunStatus::Running => write!(f, "running"),
            RunStatus::Completed => write!(f, "completed"),
            RunStatus::Failed => write!(f, "failed"),
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
}

/// Shared state for a single run.
pub struct RunState {
    pub run_id: String,
    pub thread_id: String,
    events: std::sync::Mutex<Option<broadcast::Sender<RunEvent>>>,
    pub status: RwLock<RunStatus>,
    pub error: RwLock<Option<String>>,
    pub started_at: String,
    pub updated_at: RwLock<String>,
    pub abort: Mutex<Option<AbortHandle>>,
    pub parts: std::sync::Mutex<Vec<MessagePart>>,
    pub permission_request: std::sync::Mutex<Option<PermissionRequest>>,
}

impl RunState {
    /// Add or replace a streamed part. Tool-call parts are replaced by id so
    /// updates (progress, output) keep the same slot; text and thinking parts
    /// are appended.
    pub fn apply_part(&self, part: MessagePart) {
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
        parts.push(part);
    }

    pub fn set_permission_request(&self, req: Option<PermissionRequest>) {
        if let Ok(mut guard) = self.permission_request.lock() {
            *guard = req;
        }
    }

    /// Emit an event to all current listeners. Returns the number of receivers.
    pub fn emit(&self, event: &str, data: &str) -> usize {
        let Ok(guard) = self.events.lock() else {
            return 0;
        };
        if let Some(sender) = guard.as_ref() {
            sender
                .send(RunEvent {
                    event: event.to_string(),
                    data: data.to_string(),
                })
                .unwrap_or_default()
        } else {
            0
        }
    }

    /// Create a new event receiver, or `None` if the sender has closed.
    pub fn subscribe(&self) -> Option<broadcast::Receiver<RunEvent>> {
        self.events.lock().ok().and_then(|g| g.as_ref().map(|s| s.subscribe()))
    }

    /// Close the event sender so SSE streams end.
    pub fn close(&self) {
        if let Ok(mut guard) = self.events.lock() {
            guard.take();
        }
    }

    pub async fn set_status(&self, status: RunStatus) {
        *self.status.write().await = status;
        *self.updated_at.write().await = chrono::Utc::now().to_rfc3339();
    }

    pub async fn set_error(&self, error: String) {
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
        let text = collect_text(&parts);
        let thinking = collect_thinking(&parts);
        let thinking_active = matches!(parts.last(), Some(MessagePart::Thinking { .. }));
        let tool_calls = parts
            .iter()
            .filter(|p| matches!(p, MessagePart::ToolCall { .. }))
            .cloned()
            .collect();

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

    /// Start a new background run for `thread_id`. If a run is already active,
    /// it is aborted and replaced.
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

        let (events, _) = broadcast::channel(256);
        let now = chrono::Utc::now().to_rfc3339();
        let state = Arc::new(RunState {
            run_id: Uuid::new_v4().to_string(),
            thread_id: thread_id.clone(),
            events: std::sync::Mutex::new(Some(events)),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: now.clone(),
            updated_at: RwLock::new(now),
            abort: Mutex::new(None),
            parts: std::sync::Mutex::new(Vec::new()),
            permission_request: std::sync::Mutex::new(None),
        });

        let state_for_task = state.clone();
        let runs_for_cleanup = self.runs.clone();
        let thread_id_for_cleanup = thread_id.clone();
        let handle = tokio::spawn(async move {
            let result = f(state_for_task.clone()).await;
            match result {
                Ok(()) => {
                    let _ = state_for_task.set_status(RunStatus::Completed).await;
                }
                Err(e) => {
                    let _ = state_for_task.set_error(e.to_string()).await;
                    let _ = state_for_task.set_status(RunStatus::Failed).await;
                    state_for_task.emit("error", &e.to_string());
                }
            }
            // Close the broadcast so in-flight SSE streams end, but keep the
            // run record around long enough for clients to reconnect and see
            // the final snapshot after a long run.
            state_for_task.close();
            tokio::time::sleep(std::time::Duration::from_secs(120)).await;
            runs_for_cleanup.lock().await.remove(&thread_id_for_cleanup);
        });

        {
            let mut abort = state.abort.lock().await;
            *abort = Some(handle.abort_handle());
        }

        runs.insert(thread_id, state.clone());
        Ok(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{MessagePart, ToolCallEvent};

    #[tokio::test]
    async fn run_state_accumulates_text_and_thinking_for_snapshot() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            events: std::sync::Mutex::new(None),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: Mutex::new(None),
            parts: std::sync::Mutex::new(vec![
                MessagePart::text("Hello "),
                MessagePart::thinking("hmm"),
                MessagePart::text("world"),
            ]),
            permission_request: std::sync::Mutex::new(None),
        };

        state.apply_part(MessagePart::tool_call(ToolCallEvent {
            id: "tc-1".into(),
            title: "Read".into(),
            kind: "read".into(),
            status: "completed".into(),
            command: None,
            output: None,
            output_preview: None,
            changed_files: vec![],
        }));

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
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: Mutex::new(None),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
        };

        state.apply_part(MessagePart::tool_call(ToolCallEvent {
            id: "tc-1".into(),
            title: "Read".into(),
            kind: "read".into(),
            status: "in_progress".into(),
            command: None,
            output: None,
            output_preview: None,
            changed_files: vec![],
        }));
        state.apply_part(MessagePart::tool_call(ToolCallEvent {
            id: "tc-1".into(),
            title: "Read".into(),
            kind: "read".into(),
            status: "completed".into(),
            command: Some("cat file".into()),
            output: Some("hello".into()),
            output_preview: None,
            changed_files: vec![],
        }));

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.parts.len(), 1);
        assert_eq!(snapshot.tool_calls.len(), 1);
    }
}
