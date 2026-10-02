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

/// Largest single JSON-RPC line accepted from stdout. Truncated lines fail
/// parsing and are skipped, so a runaway server cannot grow memory without
/// bound.
const MAX_STDOUT_LINE: usize = 4 * 1024 * 1024;

/// Per-line cap for stderr drain output; stderr is log noise only.
const MAX_STDERR_LINE: usize = 16 * 1024;

/// Backpressure bound on queued server events. Once full, the reader task
/// pauses instead of buffering without limit.
const EVENT_CHANNEL_CAP: usize = 1024;

/// Read one `\n`-terminated line into `buf`, capping its length at `max`.
/// Oversized lines are truncated and the remainder discarded up to the
/// newline so framing stays intact. Returns `Ok(None)` on EOF.
async fn next_capped_line<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    buf: &mut Vec<u8>,
    max: usize,
) -> std::io::Result<Option<()>> {
    buf.clear();
    let mut skipping = false;
    loop {
        let avail = reader.fill_buf().await?;
        if avail.is_empty() {
            return Ok(if buf.is_empty() { None } else { Some(()) });
        }
        let (take, keep) = match avail.iter().position(|&b| b == b'\n') {
            Some(pos) => (pos + 1, pos),
            None => (avail.len(), avail.len()),
        };
        if !skipping {
            let room = max.saturating_sub(buf.len());
            let copy = keep.min(room);
            buf.extend_from_slice(&avail[..copy]);
            skipping = keep > room;
        }
        reader.consume(take);
        if take > keep {
            return Ok(Some(()));
        }
    }
}

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
    events: Mutex<mpsc::Receiver<ServerEvent>>,
    next_id: AtomicU64,
    _child: Child,
}

impl AppServer {
    /// Spawn `bin app-server --stdio` rooted at `cwd` and start the reader.
    /// `env` adds process-level variables such as the merged `CODEX_HOME`
    /// the MCP config builds.
    pub async fn spawn(
        bin: &str,
        cwd: &Path,
        env: &[(String, String)],
    ) -> anyhow::Result<Arc<Self>> {
        let mut child = {
            let mut last_err = None;
            let mut spawned = None;
            // ETXTBSY can fire when exec'ing a binary that was written moments
            // ago (installer mid-copy, tests); retry briefly.
            for _ in 0..5 {
                let mut cmd = Command::new(bin);
                cmd.args(["app-server", "--stdio"])
                    .envs(env.iter().cloned())
                    .current_dir(cwd)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .kill_on_drop(true);
                // A fresh process group lets teardown signal grandchildren
                // too; kill_on_drop alone only reaches the direct child.
                #[cfg(unix)]
                cmd.process_group(0);
                match cmd.spawn() {
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
                let mut reader = BufReader::new(stderr);
                let mut buf = Vec::new();
                while let Ok(Some(())) =
                    next_capped_line(&mut reader, &mut buf, MAX_STDERR_LINE).await
                {
                    let line = String::from_utf8_lossy(&buf);
                    let line = line.trim();
                    if !line.is_empty() {
                        tracing::debug!(target: "codex-app-server", "{line}");
                    }
                }
            });
        }

        let (event_tx, event_rx) = mpsc::channel::<ServerEvent>(EVENT_CHANNEL_CAP);
        let pending: Arc<Mutex<PendingMap>> = Arc::new(Mutex::new(HashMap::new()));
        let reader_pending = pending.clone();

        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                match next_capped_line(&mut reader, &mut buf, MAX_STDOUT_LINE).await {
                    Ok(Some(())) => {
                        let Some(msg) = parse_message(&String::from_utf8_lossy(&buf)) else {
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
                                    .await
                                    .is_err()
                                {
                                    return;
                                }
                            }
                            Incoming::Notification { method, params } => {
                                if event_tx
                                    .send(ServerEvent::Notification { method, params })
                                    .await
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
                        let _ = event_tx.send(ServerEvent::Closed).await;
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

    /// On unix the child leads its own process group, so teardown signals
    /// the whole group — sandboxed grandchildren die with the app-server
    /// instead of surviving a cancel.
    #[cfg(unix)]
    fn teardown(&self) {
        if let Some(pgid) = self
            ._child
            .id()
            .and_then(|raw| rustix::process::Pid::from_raw(raw as i32))
        {
            let _ = rustix::process::kill_process_group(pgid, rustix::process::Signal::KILL);
        }
    }

    #[cfg(not(unix))]
    fn teardown(&self) {}

    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        self.request_with_timeout(method, params, std::time::Duration::from_secs(120))
            .await
    }

    async fn request_with_timeout(
        &self,
        method: &str,
        params: Value,
        dur: std::time::Duration,
    ) -> anyhow::Result<Value> {
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

        let result = match tokio::time::timeout(dur, rx).await {
            Err(_) => {
                // Drop the pending entry or it lingers until the server dies.
                self.pending.lock().await.remove(&id);
                return Err(anyhow::anyhow!(
                    "codex app-server request {method} timed out"
                ));
            }
            Ok(rx) => {
                rx.map_err(|_| anyhow::anyhow!("codex app-server dropped response channel"))?
            }
        };

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

impl Drop for AppServer {
    fn drop(&mut self) {
        self.teardown();
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
        let server = AppServer::spawn(&bin, dir.path(), &[]).await.unwrap();
        let resp = server.request("ping", json!({})).await.unwrap();
        assert_eq!(resp["pong"], true);
    }

    #[tokio::test]
    async fn capped_line_truncates_oversized_lines() {
        let mut reader: &[u8] =
            b"short\nthis is a very long line that exceeds the cap\nnext\n".as_slice();
        let mut buf = Vec::new();

        next_capped_line(&mut reader, &mut buf, 10).await.unwrap();
        assert_eq!(buf, b"short");

        next_capped_line(&mut reader, &mut buf, 10).await.unwrap();
        assert_eq!(buf, b"this is a ");

        // Framing survives the truncation: the next line reads cleanly.
        next_capped_line(&mut reader, &mut buf, 10).await.unwrap();
        assert_eq!(buf, b"next");

        assert!(next_capped_line(&mut reader, &mut buf, 10)
            .await
            .unwrap()
            .is_none());
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn timed_out_request_removes_its_pending_entry() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("codex");
        std::fs::write(&path, "#!/bin/sh\nwhile IFS= read -r line; do :; done\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();

        let server = AppServer::spawn(&path.to_string_lossy(), dir.path(), &[])
            .await
            .unwrap();
        let err = server
            .request_with_timeout("ping", json!({}), std::time::Duration::from_millis(50))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("timed out"), "{err}");
        assert!(server.pending.lock().await.is_empty());
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn drop_kills_the_process_group() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("codex");
        // The fake spawns a grandchild in its process group and then blocks
        // on stdin forever. kill_on_drop alone would leave the grandchild.
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\nsh -c 'echo $$ > \"{0}/grandchild.pid\"; exec sleep 600' &\nwhile IFS= read -r line; do :; done\n",
                dir.path().display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();

        let server = AppServer::spawn(&path.to_string_lossy(), dir.path(), &[])
            .await
            .unwrap();
        let mut gpid = None;
        for _ in 0..40 {
            if let Ok(raw) = std::fs::read_to_string(dir.path().join("grandchild.pid")) {
                gpid = raw.trim().parse::<i32>().ok();
                if gpid.is_some() {
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        let gpid = rustix::process::Pid::from_raw(gpid.expect("grandchild pid")).unwrap();

        drop(server);

        let mut alive = true;
        for _ in 0..60 {
            if matches!(
                rustix::process::test_kill_process(gpid),
                Err(e) if e == rustix::io::Errno::SRCH
            ) {
                alive = false;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(!alive, "grandchild survived the app-server teardown");
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn server_request_and_notification_arrive() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let server = AppServer::spawn(&bin, dir.path(), &[]).await.unwrap();
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
