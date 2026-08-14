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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunSnapshot {
    pub run_id: String,
    pub thread_id: String,
    pub status: RunStatus,
    pub started_at: String,
    pub updated_at: String,
    pub error: Option<String>,
}

/// Shared state for a single run.
pub struct RunState {
    pub run_id: String,
    pub thread_id: String,
    pub events: broadcast::Sender<RunEvent>,
    pub status: RwLock<RunStatus>,
    pub error: RwLock<Option<String>>,
    pub started_at: String,
    pub updated_at: RwLock<String>,
    pub abort: Mutex<Option<AbortHandle>>,
}

impl RunState {
    /// Emit an event to all current listeners. Returns the number of receivers.
    pub fn emit(&self, event: &str, data: &str) -> usize {
        match self.events.send(RunEvent {
            event: event.to_string(),
            data: data.to_string(),
        }) {
            Ok(n) => n,
            Err(_) => 0,
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
        RunSnapshot {
            run_id: self.run_id.clone(),
            thread_id: self.thread_id.clone(),
            status: *self.status.read().await,
            started_at: self.started_at.clone(),
            updated_at: self.updated_at.read().await.clone(),
            error: self.error.read().await.clone(),
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
        self.runs.lock().await.get(thread_id).map(|r| r.events.subscribe())
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
            events,
            status: RwLock::new(RunStatus::Running),
            error: RwLock::new(None),
            started_at: now.clone(),
            updated_at: RwLock::new(now),
            abort: Mutex::new(None),
        });

        let state_for_task = state.clone();
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
        });

        {
            let mut abort = state.abort.lock().await;
            *abort = Some(handle.abort_handle());
        }

        runs.insert(thread_id, state.clone());
        Ok(state)
    }
}
