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

use crate::plan::Plan;
use crate::providers::{AskRequest, MessagePart, PermissionRequest};

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
    pub thinking_active: bool,
    pub parts: Vec<MessagePart>,
    pub permission_request: Option<PermissionRequest>,
    pub ask_request: Option<AskRequest>,
    pub plan: Option<Plan>,
    pub last_seq: u64,
}

/// One run's status transition, broadcast runner-wide so a client can watch
/// every thread's progress over a single stream instead of polling each
/// thread's endpoint.
#[derive(Clone, Debug, Serialize)]
pub struct RunLifecycleEvent {
    pub thread_id: String,
    pub run_id: String,
    /// Owner of the thread, captured when the run starts. The SSE fan-out
    /// filters on this instead of a per-event DB lookup, which also keeps
    /// terminal events flowing for a thread deleted mid-run.
    #[serde(skip)]
    pub user_id: i64,
    pub status: RunStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// "permission" while the run waits on a permission decision, "ask"
    /// while it waits on answers. Absent on terminal statuses and while the
    /// run is making progress on its own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention: Option<String>,
    pub updated_at: String,
}

/// Shared state for a single run.
pub struct RunState {
    pub run_id: String,
    pub thread_id: String,
    /// Owner of the thread; copied onto every lifecycle event so fan-out
    /// filtering survives the thread row being deleted mid-run.
    pub user_id: i64,
    events: std::sync::Mutex<Option<broadcast::Sender<RunEvent>>>,
    initial_receiver: std::sync::Mutex<Option<broadcast::Receiver<RunEvent>>>,
    next_seq: std::sync::atomic::AtomicU64,
    pub status: RwLock<RunStatus>,
    pub error: RwLock<Option<String>>,
    pub started_at: String,
    pub updated_at: RwLock<String>,
    pub abort: std::sync::Mutex<Option<AbortHandle>>,
    /// Set once the run's provider task has returned. The wrapping task may
    /// keep the run record alive afterwards, so status alone cannot be used
    /// to tell when the worktree is safe to remove.
    pub task_done: AtomicBool,
    pub cancelled: Arc<AtomicBool>,
    pub parts: std::sync::Mutex<Vec<MessagePart>>,
    pub permission_request: std::sync::Mutex<Option<PermissionRequest>>,
    pub ask_request: std::sync::Mutex<Option<AskRequest>>,
    pub plan: std::sync::Mutex<Option<Plan>>,
    /// Runner-wide lifecycle feed. Status transitions and attention changes
    /// are republished here so clients watching all threads see them.
    lifecycle: Option<broadcast::Sender<RunLifecycleEvent>>,
}

impl RunState {
    /// Add or replace a streamed part. Tool-call parts are replaced by id so
    /// updates (progress, output) keep the same slot; text and thinking parts
    /// are appended. Updates for non-tool parts are ignored because they have
    /// no stable identity.
    pub fn apply_part(&self, part: MessagePart, is_update: bool) {
        let mut parts = self.parts.lock().unwrap_or_else(|e| e.into_inner());
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
            let same = guard.as_ref().map(|r| r.request_id.as_str())
                == req.as_ref().map(|r| r.request_id.as_str());
            if same {
                return;
            }
            *guard = req;
        }
        self.publish_attention();
    }

    pub fn set_ask_request(&self, req: Option<AskRequest>) {
        if let Ok(mut guard) = self.ask_request.lock() {
            let same = guard.as_ref().map(|r| r.request_id.as_str())
                == req.as_ref().map(|r| r.request_id.as_str());
            if same {
                return;
            }
            *guard = req;
        }
        self.publish_attention();
    }

    pub fn set_plan(&self, plan: Option<Plan>) {
        if let Ok(mut guard) = self.plan.lock() {
            *guard = plan;
        }
    }

    /// Emit an event to all current listeners. Returns the number of receivers.
    pub fn emit(&self, event: &str, data: &str) -> usize {
        let seq = self
            .next_seq
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;
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
        self.events
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|s| s.subscribe()))
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

    /// Whether the provider task has ended: returned, panicked, or aborted.
    /// The wrapping task outlives it (retention tail), so the join handle is
    /// consulted through its abort handle too.
    pub fn task_finished(&self) -> bool {
        self.task_done.load(Ordering::SeqCst)
            || self
                .abort
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|h| h.is_finished())
    }

    /// `Some("permission")` while a permission request is open,
    /// `Some("ask")` while an ask request is open. Permission wins when both
    /// are pending, matching the UI's tag priority.
    pub fn current_attention(&self) -> Option<&'static str> {
        if self
            .permission_request
            .lock()
            .map(|g| g.is_some())
            .unwrap_or(false)
        {
            return Some("permission");
        }
        if self
            .ask_request
            .lock()
            .map(|g| g.is_some())
            .unwrap_or(false)
        {
            return Some("ask");
        }
        None
    }

    pub async fn set_status(&self, status: RunStatus) {
        let mut guard = self.status.write().await;
        if status != RunStatus::Stopped && self.cancelled.load(Ordering::SeqCst) {
            return;
        }
        let changed = *guard != status;
        *guard = status;
        let now = chrono::Utc::now().to_rfc3339();
        *self.updated_at.write().await = now;
        // Publish while still holding the status write lock so racing
        // transitions (e.g. stop vs. provider failure) reach subscribers in
        // status order. publish_lifecycle only touches other locks.
        if changed {
            self.publish_lifecycle(status).await;
        }
    }

    /// Republish the run's status to lifecycle subscribers. Callers hold the
    /// status write lock to serialize event order.
    async fn publish_lifecycle(&self, status: RunStatus) {
        let Some(tx) = &self.lifecycle else { return };
        let error = if status == RunStatus::Failed {
            self.error.read().await.clone()
        } else {
            None
        };
        let _ = tx.send(RunLifecycleEvent {
            thread_id: self.thread_id.clone(),
            run_id: self.run_id.clone(),
            user_id: self.user_id,
            status,
            error,
            attention: if status == RunStatus::Running {
                self.current_attention().map(str::to_string)
            } else {
                None
            },
            updated_at: self.updated_at.read().await.clone(),
        });
    }

    /// Notify lifecycle subscribers that the run now waits on (or just left)
    /// a permission/ask request. Only meaningful while the run is live; a
    /// status write in progress carries the current attention on its own
    /// event instead.
    fn publish_attention(&self) {
        let Some(tx) = &self.lifecycle else { return };
        if !matches!(self.status.try_read().map(|s| *s), Ok(RunStatus::Running)) {
            return;
        }
        let _ = tx.send(RunLifecycleEvent {
            thread_id: self.thread_id.clone(),
            run_id: self.run_id.clone(),
            user_id: self.user_id,
            status: RunStatus::Running,
            error: None,
            attention: self.current_attention().map(str::to_string),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });
    }

    pub async fn set_error(&self, error: String) {
        if self.cancelled.load(Ordering::SeqCst) {
            return;
        }
        *self.error.write().await = Some(error);
    }

    pub async fn snapshot(&self) -> RunSnapshot {
        let parts = self.parts.lock().unwrap_or_else(|e| e.into_inner()).clone();
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
        let plan = self.plan.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // Whitespace-only parts render nothing, so the flag tracks the last
        // visible part rather than the raw tail.
        let thinking_active = matches!(
            parts.iter().rev().find(|p| match p {
                MessagePart::Text { content } | MessagePart::Thinking { content } => {
                    !content.trim().is_empty()
                }
                MessagePart::ToolCall { .. } => true,
            }),
            Some(MessagePart::Thinking { .. })
        );

        let last_seq = self.next_seq.load(std::sync::atomic::Ordering::SeqCst);

        RunSnapshot {
            run_id: self.run_id.clone(),
            thread_id: self.thread_id.clone(),
            status: *self.status.read().await,
            started_at: self.started_at.clone(),
            updated_at: self.updated_at.read().await.clone(),
            error: self.error.read().await.clone(),
            thinking_active,
            parts,
            permission_request,
            ask_request,
            plan,
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
    lifecycle: broadcast::Sender<RunLifecycleEvent>,
}

impl Default for ThreadRunner {
    fn default() -> Self {
        Self::new()
    }
}

impl ThreadRunner {
    pub fn new() -> Self {
        let (lifecycle, _) = broadcast::channel(256);
        Self {
            runs: Arc::new(Mutex::new(HashMap::new())),
            lifecycle,
        }
    }

    /// Subscribe to every run status transition across all threads. Events
    /// only describe changes after subscription; the current picture comes
    /// from `running_ids` and per-run snapshots.
    pub fn subscribe_lifecycle(&self) -> broadcast::Receiver<RunLifecycleEvent> {
        self.lifecycle.subscribe()
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

    /// Every run still tracked: live ones plus finished records kept around
    /// for reconnecting clients (the retention tail removes them later).
    pub async fn all_runs(&self) -> Vec<Arc<RunState>> {
        self.runs.lock().await.values().cloned().collect()
    }

    /// Start a new background run for `thread_id`. If a run is already active,
    /// returns `AlreadyRunning`.
    pub async fn start<F, Fut>(
        &self,
        thread_id: String,
        user_id: i64,
        f: F,
    ) -> Result<Arc<RunState>, StartError>
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
            user_id,
            events: std::sync::Mutex::new(Some(events)),
            initial_receiver: std::sync::Mutex::new(Some(initial_rx)),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: now.clone(),
            updated_at: RwLock::new(now),
            abort: std::sync::Mutex::new(None),
            task_done: AtomicBool::new(false),
            cancelled: Arc::new(AtomicBool::new(false)),
            parts: std::sync::Mutex::new(Vec::new()),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: Some(self.lifecycle.clone()),
        });

        runs.insert(thread_id.clone(), state.clone());
        // Publish before spawning: a task that finishes instantly must not
        // emit its terminal event ahead of the running one.
        let _ = self.lifecycle.send(RunLifecycleEvent {
            thread_id: state.thread_id.clone(),
            run_id: state.run_id.clone(),
            user_id: state.user_id,
            status: RunStatus::Running,
            error: None,
            attention: None,
            updated_at: state.started_at.clone(),
        });

        let state_for_task = state.clone();
        let state_for_cleanup = state.clone();
        let runs_for_cleanup = self.runs.clone();
        let thread_id_for_cleanup = thread_id.clone();
        let handle = tokio::spawn(async move {
            let result = f(state_for_task.clone()).await;
            state_for_task.task_done.store(true, Ordering::SeqCst);
            if !state_for_task.cancelled.load(Ordering::SeqCst) {
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
        // doesn't respond to cancellation. The handle stays on the run so
        // `wait_finished` can observe the task actually ending.
        let abort_handle = run.abort.lock().unwrap().clone();
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

    /// Wait until the run's provider task has actually ended, gracefully or
    /// via the hard abort `stop` schedules, up to `timeout`. Returns early
    /// when the thread has no run. A run that was displaced in the map by a
    /// newer `start` is watched too, so a still-draining cancelled run is
    /// not lost sight of. Used before removing a thread's worktree so the
    /// agent is not left writing inside a deleted directory.
    pub async fn wait_finished(&self, thread_id: &str, timeout: std::time::Duration) {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut watched: Vec<Arc<RunState>> = Vec::new();
        loop {
            if let Some(run) = self.runs.lock().await.get(thread_id).cloned() {
                if !watched.iter().any(|r| Arc::ptr_eq(r, &run)) {
                    watched.push(run);
                }
            }
            if watched.iter().all(|r| r.task_finished()) || tokio::time::Instant::now() >= deadline
            {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
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
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![
                MessagePart::text("Hello "),
                MessagePart::thinking("hmm"),
                MessagePart::text("world"),
            ]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
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
        assert_eq!(snapshot.parts.len(), 4);
        let text_parts: Vec<&str> = snapshot
            .parts
            .iter()
            .filter_map(|p| match p {
                MessagePart::Text { content } => Some(content.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text_parts.concat(), "Hello world");
        assert!(snapshot
            .parts
            .iter()
            .any(|p| matches!(p, MessagePart::Thinking { .. })));
        assert!(!snapshot.thinking_active);
        assert!(snapshot
            .parts
            .iter()
            .any(|p| matches!(p, MessagePart::ToolCall { .. })));
    }

    #[tokio::test]
    async fn run_state_thinking_active_ignores_whitespace_tail() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![
                MessagePart::thinking("hmm"),
                MessagePart::text(" "),
            ]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
        };

        assert!(state.snapshot().await.thinking_active);
    }

    #[tokio::test]
    async fn run_state_replaces_tool_call_by_id() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
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
        assert!(snapshot
            .parts
            .iter()
            .any(|p| matches!(p, MessagePart::ToolCall { .. })));
    }

    #[tokio::test]
    async fn run_state_does_not_append_text_update() {
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![MessagePart::text("first ")]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
        };

        state.apply_part(MessagePart::text("second "), true);

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.parts.len(), 1);
        assert_eq!(
            snapshot.parts.first().and_then(|p| p.text_content()),
            Some("first ")
        );
    }

    #[tokio::test]
    async fn run_state_assigns_increasing_seq_numbers() {
        let (events, initial_rx) = broadcast::channel(8);
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            user_id: 1,
            events: std::sync::Mutex::new(Some(events)),
            initial_receiver: std::sync::Mutex::new(Some(initial_rx)),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
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
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: None,
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
            .start("t1".into(), 1, |_state| async {
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

    #[tokio::test]
    async fn lifecycle_events_cover_start_and_finish() {
        let runner = ThreadRunner::new();
        let mut rx = runner.subscribe_lifecycle();
        let run = runner
            .start("t1".into(), 1, |_state| async { Ok(()) })
            .await
            .unwrap();

        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.thread_id, "t1");
        assert_eq!(ev.run_id, run.run_id);
        assert_eq!(ev.status, RunStatus::Running);

        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.thread_id, "t1");
        assert_eq!(ev.status, RunStatus::Completed);
        assert!(ev.error.is_none());
    }

    #[tokio::test]
    async fn lifecycle_events_cover_concurrent_runs() {
        let runner = ThreadRunner::new();
        let mut rx = runner.subscribe_lifecycle();
        runner
            .start("t1".into(), 1, |_state| async { Ok(()) })
            .await
            .unwrap();
        runner
            .start("t2".into(), 1, |_state| async { Ok(()) })
            .await
            .unwrap();

        let mut events = Vec::new();
        for _ in 0..4 {
            events.push(rx.recv().await.unwrap());
        }
        let running: Vec<&str> = events
            .iter()
            .filter(|e| e.status == RunStatus::Running)
            .map(|e| e.thread_id.as_str())
            .collect();
        let completed: Vec<&str> = events
            .iter()
            .filter(|e| e.status == RunStatus::Completed)
            .map(|e| e.thread_id.as_str())
            .collect();
        assert!(running.contains(&"t1") && running.contains(&"t2"));
        assert!(completed.contains(&"t1") && completed.contains(&"t2"));
    }

    #[tokio::test]
    async fn lifecycle_event_carries_error_on_failure() {
        let runner = ThreadRunner::new();
        let mut rx = runner.subscribe_lifecycle();
        runner
            .start("t1".into(), 1, |_state| async {
                Err(anyhow::anyhow!("boom"))
            })
            .await
            .unwrap();

        loop {
            let ev = rx.recv().await.unwrap();
            if ev.status == RunStatus::Failed {
                assert_eq!(ev.thread_id, "t1");
                assert_eq!(ev.error.as_deref(), Some("boom"));
                break;
            }
        }
    }

    #[tokio::test]
    async fn lifecycle_events_cover_stop() {
        let runner = ThreadRunner::new();
        let mut rx = runner.subscribe_lifecycle();
        runner
            .start("t1".into(), 1, |_state| async {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                Ok(())
            })
            .await
            .unwrap();
        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.status, RunStatus::Running);

        runner.stop("t1").await;
        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.thread_id, "t1");
        assert_eq!(ev.status, RunStatus::Stopped);
    }

    #[tokio::test]
    async fn attention_events_fire_on_permission_and_ask() {
        let (tx, mut rx) = broadcast::channel(8);
        let state = RunState {
            run_id: "r1".into(),
            thread_id: "t1".into(),
            user_id: 1,
            events: std::sync::Mutex::new(None),
            initial_receiver: std::sync::Mutex::new(None),
            next_seq: std::sync::atomic::AtomicU64::new(0),
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: chrono::Utc::now().to_rfc3339(),
            updated_at: RwLock::new(chrono::Utc::now().to_rfc3339()),
            abort: std::sync::Mutex::new(None),
            task_done: std::sync::atomic::AtomicBool::new(false),
            cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            parts: std::sync::Mutex::new(vec![]),
            permission_request: std::sync::Mutex::new(None),
            ask_request: std::sync::Mutex::new(None),
            plan: std::sync::Mutex::new(None),
            lifecycle: Some(tx),
        };

        state.set_permission_request(Some(PermissionRequest {
            request_id: "p1".into(),
            scope: "fs".into(),
            title: "Write file".into(),
            input: None,
            options: vec![],
        }));
        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.status, RunStatus::Running);
        assert_eq!(ev.attention.as_deref(), Some("permission"));

        state.set_permission_request(None);
        state.set_ask_request(Some(AskRequest {
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
        }));
        // The cleared permission request publishes first, then the ask.
        let ev = rx.recv().await.unwrap();
        assert!(ev.attention.is_none());
        let ev = rx.recv().await.unwrap();
        assert_eq!(ev.attention.as_deref(), Some("ask"));

        // A finished run no longer publishes attention changes.
        state.set_status(RunStatus::Completed).await;
        state.set_ask_request(None);
        while let Ok(ev) = rx.try_recv() {
            assert!(ev.attention.is_none() || ev.status == RunStatus::Running);
            if ev.status == RunStatus::Completed {
                return;
            }
        }
        panic!("expected a completed lifecycle event");
    }
}
