//! In-memory manager for remote terminal sessions.
//!
//! Sessions are keyed by UUID, scoped to a user and thread, and removed if
//! they are idle longer than the configured TTL.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use tokio::sync::Mutex;
use tokio::time::Duration;

use super::session::TerminalSession;

#[derive(Clone)]
pub struct TerminalManager {
    inner: Arc<Mutex<TerminalManagerInner>>,
    ttl: Duration,
    cleanup_interval: Duration,
    _cleanup_task: Arc<tokio::task::JoinHandle<()>>,
}

struct TerminalManagerInner {
    sessions: HashMap<String, Arc<TerminalSession>>,
}

impl TerminalManager {
    pub fn new(ttl: Duration, cleanup_interval: Duration) -> Self {
        let inner = Arc::new(Mutex::new(TerminalManagerInner {
            sessions: HashMap::new(),
        }));
        let task_inner = inner.clone();
        let task_ttl = ttl;
        let _cleanup_task = Arc::new(tokio::spawn(async move {
            let mut interval = tokio::time::interval(cleanup_interval);
            loop {
                interval.tick().await;
                let mut guard = task_inner.lock().await;
                let now = super::session::now_millis();
                let expired: Vec<String> = guard
                    .sessions
                    .iter()
                    .filter(|(_, s)| {
                        s.is_shutdown()
                            || now.saturating_sub(s.last_activity()) > task_ttl.as_millis() as u64
                    })
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in expired {
                    if let Some(s) = guard.sessions.remove(&id) {
                        let _ = s.kill();
                    }
                }
            }
        }));

        Self {
            inner,
            ttl,
            cleanup_interval,
            _cleanup_task,
        }
    }

    /// Default manager: 30-minute TTL, 60-second cleanup sweep.
    pub fn default_manager() -> Self {
        Self::new(
            Duration::from_secs(30 * 60),
            Duration::from_secs(60),
        )
    }

    /// Spawn a new PTY session for `user_id` and `thread_id`. If `shell` is
    /// provided it is used as the shell program; otherwise `bash` is preferred
    /// with a fallback to `sh`.
    pub async fn spawn(
        &self,
        user_id: i64,
        thread_id: String,
        shell: Option<&str>,
    ) -> Result<Arc<TerminalSession>> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open pty")?;

        let program = shell
            .map(String::from)
            .unwrap_or_else(|| default_shell_program());

        let cmd = CommandBuilder::new(&program);
        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;

        let writer = pair.master.take_writer().context("take pty writer")?;

        let id = uuid::Uuid::new_v4().to_string();
        let session = TerminalSession::spawn(id.clone(), thread_id, user_id, pair.master, writer, child)?;

        let mut guard = self.inner.lock().await;
        guard.sessions.insert(id, session.clone());
        Ok(session)
    }

    pub async fn get(&self, id: &str) -> Option<Arc<TerminalSession>> {
        let guard = self.inner.lock().await;
        guard.sessions.get(id).cloned()
    }

    pub async fn kill(&self, id: &str) -> Result<()> {
        let session = {
            let mut guard = self.inner.lock().await;
            guard.sessions.remove(id)
        };
        match session {
            Some(s) => s.kill(),
            None => Err(anyhow::anyhow!("session not found")),
        }
    }

    pub async fn list_for_thread(&self, thread_id: &str) -> Vec<Arc<TerminalSession>> {
        let guard = self.inner.lock().await;
        guard
            .sessions
            .values()
            .filter(|s| s.thread_id == thread_id)
            .cloned()
            .collect()
    }

    #[allow(dead_code)]
    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    #[allow(dead_code)]
    pub fn cleanup_interval(&self) -> Duration {
        self.cleanup_interval
    }
}

fn default_shell_program() -> String {
    if which::which("bash").is_ok() {
        "bash".to_string()
    } else {
        "sh".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::session::TerminalEvent;

    #[tokio::test]
    async fn lifecycle_spawn_write_resize_kill() {
        let manager = TerminalManager::new(
            Duration::from_secs(60),
            Duration::from_secs(10),
        );
        let session = manager
            .spawn(1, "t1".into(), Some("cat"))
            .await
            .expect("spawn cat");
        assert_eq!(session.user_id, 1);
        assert_eq!(session.thread_id, "t1");

        let mut rx = session.subscribe();
        session.write_input("hello world\n").expect("write");

        let timeout = tokio::time::Duration::from_secs(5);
        let deadline = tokio::time::Instant::now() + timeout;

        let mut saw_output = false;
        while tokio::time::Instant::now() < deadline {
            match tokio::time::timeout(
                tokio::time::Duration::from_millis(100),
                rx.recv(),
            )
            .await
            {
                Ok(Ok(TerminalEvent::Output(bytes))) => {
                    let text = String::from_utf8_lossy(&bytes);
                    if text.contains("hello world") {
                        saw_output = true;
                        break;
                    }
                }
                _ => {}
            }
        }
        assert!(saw_output, "expected echo of 'hello world'");

        session.resize(120, 30).expect("resize");

        manager.kill(&session.id).await.expect("kill");
        assert!(manager.get(&session.id).await.is_none());
    }

    #[tokio::test]
    async fn ttl_expires_session() {
        let manager = TerminalManager::new(
            Duration::from_millis(100),
            Duration::from_millis(50),
        );
        let session = manager
            .spawn(1, "t1".into(), Some("cat"))
            .await
            .expect("spawn cat");

        // Wait for the cleanup sweep to run more than once.
        tokio::time::sleep(Duration::from_millis(400)).await;

        assert!(manager.get(&session.id).await.is_none());
    }
}
