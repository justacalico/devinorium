//! A single remote terminal session backed by a portable-pty PTY.
//!
//! The session owns the PTY master/writer, reads output in a background
//! task, and broadcasts it to any connected WebSocket clients.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use bytes::BytesMut;
use portable_pty::{Child, MasterPty, PtySize};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio::time::{interval, Duration};

/// Events broadcast from a terminal session to connected clients.
#[derive(Clone, Debug)]
pub enum TerminalEvent {
    Output(Vec<u8>),
    Exited(i32),
}

pub struct TerminalSession {
    pub id: String,
    pub thread_id: String,
    pub user_id: i64,
    pub created_at: String,
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: Arc<Mutex<Box<dyn Child + Send>>>,
    shutdown: Arc<AtomicBool>,
    last_activity: Arc<AtomicU64>,
    output_tx: broadcast::Sender<TerminalEvent>,
    _reader_task: JoinHandle<()>,
    _exit_task: JoinHandle<()>,
}

pub(super) fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

impl TerminalSession {
    pub fn spawn(
        id: String,
        thread_id: String,
        user_id: i64,
        master: Box<dyn MasterPty + Send>,
        writer: Box<dyn Write + Send>,
        child: Box<dyn Child + Send>,
    ) -> Result<Arc<Self>> {
        let created_at = chrono::Utc::now().to_rfc3339();
        let (output_tx, _output_rx) = broadcast::channel(1024);
        let master = Arc::new(Mutex::new(master));
        let writer = Arc::new(Mutex::new(writer));
        let child = Arc::new(Mutex::new(child));
        let shutdown = Arc::new(AtomicBool::new(false));
        let last_activity = Arc::new(AtomicU64::new(now_millis()));

        let reader = master
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .try_clone_reader()
            .context("clone pty reader")?;

        let (chunk_tx, mut chunk_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(256);

        let _reader_task = {
            let output_tx = output_tx.clone();
            let shutdown = shutdown.clone();
            let last_activity = last_activity.clone();
            let exit_tx = output_tx.clone();
            tokio::spawn(async move {
                let task = tokio::task::spawn_blocking({
                    let shutdown = shutdown.clone();
                    move || {
                        let mut reader = reader;
                        let mut buf = [0u8; 4096];
                        while !shutdown.load(Ordering::SeqCst) {
                            match reader.read(&mut buf) {
                                Ok(0) => break,
                                Ok(n) => {
                                    if chunk_tx.blocking_send(buf[..n].to_vec()).is_err() {
                                        break;
                                    }
                                }
                                Err(e) => {
                                    tracing::debug!(error = %e, "pty read error");
                                    break;
                                }
                            }
                        }
                    }
                });

                let mut tick = interval(Duration::from_millis(16));
                let mut buf = BytesMut::with_capacity(8192);

                // Periodically flush buffered PTY output into the broadcast channel.
                loop {
                    tokio::select! {
                        chunk = chunk_rx.recv() => match chunk {
                            Some(c) => {
                                last_activity.store(now_millis(), Ordering::SeqCst);
                                buf.extend_from_slice(&c);
                            }
                            None => break,
                        },
                        _ = tick.tick() => {
                            if !buf.is_empty() {
                                let _ = output_tx.send(TerminalEvent::Output(
                                    buf.split().freeze().to_vec(),
                                ));
                            }
                        }
                    }
                }

                // Drain any remaining output before the reader exits.
                if !buf.is_empty() {
                    let _ = exit_tx.send(TerminalEvent::Output(buf.to_vec()));
                }

                // Ensure the blocking read thread is done.
                let _ = task.await;
            })
        };

        let _exit_task = {
            let child = child.clone();
            let shutdown = shutdown.clone();
            let output_tx = output_tx.clone();
            let last_activity = last_activity.clone();
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_millis(100));
                let code = loop {
                    if shutdown.load(Ordering::SeqCst) {
                        break 0;
                    }
                    interval.tick().await;
                    let mut guard = child.lock().unwrap_or_else(|e| e.into_inner());
                    match guard.try_wait() {
                        Ok(Some(status)) => {
                            let code = if status.success() {
                                0
                            } else {
                                status.exit_code() as i32
                            };
                            break code;
                        }
                        Ok(None) => {}
                        Err(e) => {
                            tracing::debug!(error = %e, "try_wait error");
                            break -1;
                        }
                    }
                    // try_wait does not block, but sleep a bit between polls.
                    drop(guard);
                };
                last_activity.store(now_millis(), Ordering::SeqCst);
                shutdown.store(true, Ordering::SeqCst);
                let _ = output_tx.send(TerminalEvent::Exited(code));
            })
        };

        Ok(Arc::new(Self {
            id,
            thread_id,
            user_id,
            created_at,
            master,
            writer,
            child,
            shutdown,
            last_activity,
            output_tx,
            _reader_task,
            _exit_task,
        }))
    }

    pub fn touch(&self) {
        self.last_activity.store(now_millis(), Ordering::SeqCst);
    }

    pub fn last_activity(&self) -> u64 {
        self.last_activity.load(Ordering::SeqCst)
    }

    pub fn is_shutdown(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<TerminalEvent> {
        self.touch();
        self.output_tx.subscribe()
    }

    pub fn write_input(&self, data: &str) -> Result<()> {
        self.touch();
        let mut guard = self.writer.lock().unwrap_or_else(|e| e.into_inner());
        guard
            .write_all(data.as_bytes())
            .and_then(|_| guard.flush())
            .context("write to pty")?;
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        self.touch();
        let guard = self.master.lock().unwrap_or_else(|e| e.into_inner());
        guard
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("resize pty")?;
        Ok(())
    }

    pub fn send_signal(&self, sig: &str) -> Result<()> {
        self.touch();
        match sig {
            "int" => self.write_input("\x03"),
            _ => Err(anyhow::anyhow!("unsupported signal: {sig}")),
        }
    }

    pub fn kill(&self) -> Result<()> {
        self.shutdown.store(true, Ordering::SeqCst);
        let mut guard = self.child.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = guard.kill() {
            tracing::warn!(error = %e, "failed to kill terminal child");
        }
        Ok(())
    }
}
