//! Minimal JSON-RPC transport over `codex app-server --stdio`.
//!
//! One child process per prompt turn. A background task reads stdout line by
//! line, completes pending client requests, and forwards server requests and
//! notifications to the consumer through [`AppServer::next_event`]. Stderr is
//! drained into the tracing log so a chatty server cannot fill its pipe.

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, oneshot, Mutex};

use super::wire::{parse_message, Incoming};

/// A server-initiated message that needs the consumer's attention.
#[derive(Debug)]
pub enum ServerEvent {
    /// Server request: respond with [`AppServer::respond`] or
    /// [`AppServer::respond_error`].
    Request {
        id: Value,
        method: String,
        params: Value,
    },
    /// Server notification.
    Notification { method: String, params: Value },
    /// The server closed its output stream or died.
    Closed,
}

type PendingMap = HashMap<u64, oneshot::Sender<Result<Value, String>>>;

/// A running `codex app-server` child and its JSON-RPC plumbing.
pub struct AppServer {
    stdin: Mutex<ChildStdin>,
    pending: Arc<Mutex<PendingMap>>,
    events: Mutex<mpsc::UnboundedReceiver<ServerEvent>>,
    next_id: AtomicU64,
    _child: Child,
}

impl AppServer {
    /// Spawn `bin app-server --stdio` rooted at `cwd` and start the reader.
    pub async fn spawn(bin: &str, cwd: &Path) -> anyhow::Result<Arc<Self>> {
        let mut child = {
            let mut last_err = None;
            let mut spawned = None;
            // ETXTBSY can fire when exec'ing a binary that was written moments
            // ago (installer mid-copy, tests); retry briefly.
            for _ in 0..5 {
                match Command::new(bin)
                    .args(["app-server", "--stdio"])
                    .current_dir(cwd)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .kill_on_drop(true)
                    .spawn()
                {
                    Ok(c) => {
                        spawned = Some(c);
                        break;
                    }
                    Err(e) if e.raw_os_error() == Some(26) => {
                        last_err = Some(e);
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                    Err(e) => return Err(anyhow::anyhow!("failed to spawn {bin} app-server: {e}")),
                }
            }
            match spawned {
                Some(c) => c,
                None => {
                    return Err(anyhow::anyhow!(
                        "failed to spawn {bin} app-server: {}",
                        last_err.unwrap()
                    ))
                }
            }
        };

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("codex app-server has no stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("codex app-server has no stdout"))?;
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let line = line.trim();
                    if !line.is_empty() {
                        tracing::debug!(target: "codex-app-server", "{line}");
                    }
                }
            });
        }

        let (event_tx, event_rx) = mpsc::unbounded_channel::<ServerEvent>();
        let pending: Arc<Mutex<PendingMap>> = Arc::new(Mutex::new(HashMap::new()));
        let reader_pending = pending.clone();

        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let Some(msg) = parse_message(&line) else {
                            continue;
                        };
                        match msg {
                            Incoming::Response { id, result } => {
                                if let Some(key) = id.as_u64() {
                                    if let Some(tx) = reader_pending.lock().await.remove(&key) {
                                        let _ = tx.send(result);
                                    }
                                }
                            }
                            Incoming::Request { id, method, params } => {
                                if event_tx
                                    .send(ServerEvent::Request { id, method, params })
                                    .is_err()
                                {
                                    return;
                                }
                            }
                            Incoming::Notification { method, params } => {
                                if event_tx
                                    .send(ServerEvent::Notification { method, params })
                                    .is_err()
                                {
                                    return;
                                }
                            }
                        }
                    }
                    Ok(None) | Err(_) => {
                        // Fail every in-flight request, then tell the consumer.
                        let mut pending = reader_pending.lock().await;
                        for (_, tx) in pending.drain() {
                            let _ = tx.send(Err("codex app-server exited".to_string()));
                        }
                        let _ = event_tx.send(ServerEvent::Closed);
                        return;
                    }
                }
            }
        });

        Ok(Arc::new(Self {
            stdin: Mutex::new(stdin),
            pending,
            events: Mutex::new(event_rx),
            next_id: AtomicU64::new(1),
            _child: child,
        }))
    }

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);

        let write = self
            .write(&json!({ "id": id, "method": method, "params": params }))
            .await;
        if let Err(e) = write {
            self.pending.lock().await.remove(&id);
            return Err(e);
        }

        let result = tokio::time::timeout(std::time::Duration::from_secs(120), rx)
            .await
            .map_err(|_| anyhow::anyhow!("codex app-server request {method} timed out"))?
            .map_err(|_| anyhow::anyhow!("codex app-server dropped response channel"))?;

        result.map_err(|e| anyhow::anyhow!("{method} failed: {e}"))
    }

    /// Send a client notification (no id, no response).
    pub async fn notify(&self, method: &str) -> anyhow::Result<()> {
        self.write(&json!({ "method": method })).await
    }

    /// Send a request without waiting for its response. The eventual reply is
    /// discarded — used for `turn/interrupt` where only the write matters.
    pub async fn send_untracked(&self, method: &str, params: Value) -> anyhow::Result<()> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        self.write(&json!({ "id": id, "method": method, "params": params }))
            .await
    }

    /// Answer a server request successfully.
    pub async fn respond(&self, id: Value, result: Value) -> anyhow::Result<()> {
        self.write(&json!({ "id": id, "result": result })).await
    }

    /// Answer a server request with a JSON-RPC error.
    pub async fn respond_error(&self, id: Value, message: &str) -> anyhow::Result<()> {
        self.write(&json!({ "id": id, "error": { "code": -32601, "message": message } }))
            .await
    }

    /// Wait for the next server request or notification.
    pub async fn next_event(&self) -> ServerEvent {
        self.events
            .lock()
            .await
            .recv()
            .await
            .unwrap_or(ServerEvent::Closed)
    }

    async fn write(&self, msg: &Value) -> anyhow::Result<()> {
        let mut line = serde_json::to_vec(msg)?;
        line.push(b'\n');
        let mut stdin = self.stdin.lock().await;
        stdin.write_all(&line).await?;
        stdin.flush().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake `codex` binary whose `app-server --stdio` mode answers `ping`
    /// requests and emits a notification for anything else.
    #[cfg(unix)]
    fn fake_codex(dir: &Path) -> String {
        let path = dir.join("codex");
        std::fs::write(
            &path,
            r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"method":"ping"'*)
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      printf '{"id":%s,"result":{"pong":true}}\n' "$id"
      ;;
    *'"method":"askme"'*)
      printf '%s\n' '{"id":"srv-1","method":"item/commandExecution/requestApproval","params":{"command":"ls"}}'
      ;;
    *)
      printf '%s\n' '{"method":"seen","params":{}}'
      ;;
  esac
done
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.to_string_lossy().to_string()
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn request_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let server = AppServer::spawn(&bin, dir.path()).await.unwrap();
        let resp = server.request("ping", json!({})).await.unwrap();
        assert_eq!(resp["pong"], true);
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn server_request_and_notification_arrive() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let server = AppServer::spawn(&bin, dir.path()).await.unwrap();
        server.notify("askme").await.unwrap();

        match server.next_event().await {
            ServerEvent::Request { method, .. } => {
                assert_eq!(method, "item/commandExecution/requestApproval")
            }
            other => panic!("expected request, got {other:?}"),
        }
        server.notify("whatever").await.unwrap();
        match server.next_event().await {
            ServerEvent::Notification { method, .. } => assert_eq!(method, "seen"),
            other => panic!("expected notification, got {other:?}"),
        }
    }
}
