//! In-memory manager for remote terminal sessions.
//!
//! Sessions are keyed by UUID, scoped to a user and thread, and removed if
//! they are idle longer than the configured TTL.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
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
        Self::new(Duration::from_secs(30 * 60), Duration::from_secs(60))
    }

    /// Spawn a new PTY session for `user_id` and `thread_id`. If `shell` is
    /// provided it is used as the shell program; otherwise the user's default
    /// shell is resolved. `cwd` sets the shell's starting directory —
    /// pass the thread's working directory so the terminal opens where the
    /// files are.
    pub async fn spawn(
        &self,
        user_id: i64,
        thread_id: String,
        shell: Option<&str>,
        cwd: Option<PathBuf>,
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
            .unwrap_or_else(default_shell_program);

        let mut cmd = CommandBuilder::new(&program);
        if let Some(dir) = cwd {
            cmd.cwd(dir);
        }
        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;

        let writer = pair.master.take_writer().context("take pty writer")?;

        let id = uuid::Uuid::new_v4().to_string();
        let session =
            TerminalSession::spawn(id.clone(), thread_id, user_id, pair.master, writer, child)?;

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

    /// Kill every tracked session. Called on shutdown so PTYs are not left
    /// running when the process exits.
    pub async fn kill_all(&self) {
        let sessions: Vec<Arc<TerminalSession>> = {
            let mut guard = self.inner.lock().await;
            guard.sessions.drain().map(|(_, s)| s).collect()
        };
        for s in sessions {
            let _ = s.kill();
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

/// Resolve the shell to spawn when the caller does not name one. The user's
/// configured shell wins; platform fallbacks cover hosts where it is unset or
/// points at a binary that is not installed.
fn default_shell_program() -> String {
    user_shell().unwrap_or_else(fallback_shell)
}

#[cfg(unix)]
fn user_shell() -> Option<String> {
    let env_shell = std::env::var("SHELL").ok();
    let uid = rustix::process::getuid().as_raw();
    let passwd = std::fs::read_to_string("/etc/passwd").unwrap_or_default();
    resolve_user_shell(env_shell.as_deref(), &passwd, uid)
}

#[cfg(windows)]
fn user_shell() -> Option<String> {
    let comspec = std::env::var("COMSPEC").ok()?;
    let comspec = comspec.trim();
    if comspec.is_empty() {
        return None;
    }
    which::which(comspec)
        .ok()
        .map(|p| p.to_string_lossy().into_owned())
}

#[cfg(not(any(unix, windows)))]
fn user_shell() -> Option<String> {
    None
}

#[cfg(unix)]
fn fallback_shell() -> String {
    if which::which("bash").is_ok() {
        "bash".to_string()
    } else {
        "sh".to_string()
    }
}

#[cfg(windows)]
fn fallback_shell() -> String {
    if which::which("powershell.exe").is_ok() {
        "powershell.exe".to_string()
    } else {
        "cmd.exe".to_string()
    }
}

#[cfg(not(any(unix, windows)))]
fn fallback_shell() -> String {
    "sh".to_string()
}

/// Pick the first usable shell out of `$SHELL` and the user's passwd entry.
/// `$SHELL` is not always exported (daemons, containers, systemd units), so
/// the passwd entry is the fallback for the same account; accounts managed
/// outside /etc/passwd (NSS, macOS) fall through to the platform default.
#[cfg(unix)]
fn resolve_user_shell(env_shell: Option<&str>, passwd: &str, uid: u32) -> Option<String> {
    [env_shell.map(String::from), shell_from_passwd(passwd, uid)]
        .into_iter()
        .flatten()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && is_interactive_shell(s))
        .find_map(|s| which::which(&s).ok())
        .map(|p| p.to_string_lossy().into_owned())
}

/// Service accounts are commonly created with a non-interactive shell like
/// nologin; spawning one would give a terminal that exits instantly.
#[cfg(unix)]
fn is_interactive_shell(path: &str) -> bool {
    let name = Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path);
    !matches!(
        name,
        "nologin" | "false" | "true" | "sync" | "shutdown" | "halt"
    )
}

#[cfg(unix)]
fn shell_from_passwd(passwd: &str, uid: u32) -> Option<String> {
    for line in passwd.lines() {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() >= 7 && fields[2].parse::<u32>().ok() == Some(uid) {
            let shell = fields[6].trim();
            if !shell.is_empty() {
                return Some(shell.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::session::TerminalEvent;

    #[tokio::test]
    async fn lifecycle_spawn_write_resize_kill() {
        let manager = TerminalManager::new(Duration::from_secs(60), Duration::from_secs(10));
        let session = manager
            .spawn(1, "t1".into(), Some("cat"), None)
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
            if let Ok(Ok(TerminalEvent::Output(bytes))) =
                tokio::time::timeout(tokio::time::Duration::from_millis(100), rx.recv()).await
            {
                let text = String::from_utf8_lossy(&bytes);
                if text.contains("hello world") {
                    saw_output = true;
                    break;
                }
            }
        }
        assert!(saw_output, "expected echo of 'hello world'");

        session.resize(120, 30).expect("resize");

        manager.kill(&session.id).await.expect("kill");
        assert!(manager.get(&session.id).await.is_none());
    }

    #[tokio::test]
    async fn spawn_starts_shell_in_given_working_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let want = dir
            .path()
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();

        let manager = TerminalManager::new(Duration::from_secs(60), Duration::from_secs(10));
        let session = manager
            .spawn(1, "t1".into(), Some("sh"), Some(dir.path().to_path_buf()))
            .await
            .expect("spawn sh");

        let mut rx = session.subscribe();
        session.write_input("pwd\n").expect("write");

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut saw_pwd = false;
        while tokio::time::Instant::now() < deadline {
            if let Ok(Ok(TerminalEvent::Output(bytes))) =
                tokio::time::timeout(Duration::from_millis(100), rx.recv()).await
            {
                if String::from_utf8_lossy(&bytes).contains(&want) {
                    saw_pwd = true;
                    break;
                }
            }
        }
        let _ = manager.kill(&session.id).await;
        assert!(saw_pwd, "expected pwd to print {want}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn spawn_without_shell_uses_default_shell() {
        let manager = TerminalManager::new(Duration::from_secs(60), Duration::from_secs(10));
        let session = manager
            .spawn(1, "t1".into(), None, None)
            .await
            .expect("spawn default shell");

        let mut rx = session.subscribe();
        session
            .write_input("echo default-shell-marker\n")
            .expect("write");

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut saw_marker = false;
        while tokio::time::Instant::now() < deadline {
            if let Ok(Ok(TerminalEvent::Output(bytes))) =
                tokio::time::timeout(Duration::from_millis(100), rx.recv()).await
            {
                if String::from_utf8_lossy(&bytes).contains("default-shell-marker") {
                    saw_marker = true;
                    break;
                }
            }
        }
        let _ = manager.kill(&session.id).await;
        assert!(saw_marker, "expected echo from resolved default shell");
    }

    #[cfg(unix)]
    #[test]
    fn shell_from_passwd_returns_shell_for_matching_uid() {
        let passwd = "\
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000:Alice:/home/alice:/usr/bin/fish
";
        assert_eq!(
            shell_from_passwd(passwd, 1000),
            Some("/usr/bin/fish".to_string())
        );
        assert_eq!(shell_from_passwd(passwd, 0), Some("/bin/bash".to_string()));
        assert_eq!(shell_from_passwd(passwd, 4242), None);
    }

    #[cfg(unix)]
    #[test]
    fn shell_from_passwd_skips_malformed_and_empty_shell_lines() {
        let passwd = "\
not enough fields
bob:x:1001
carol:x:notauid:1002:Carol:/home/carol:/bin/zsh
dave:x:1002:1002:Dave:/home/dave:
erin:x:1002:1002:Erin:/home/erin:/bin/tcsh:extra
";
        assert_eq!(
            shell_from_passwd(passwd, 1002),
            Some("/bin/tcsh".to_string())
        );
        assert_eq!(shell_from_passwd("", 0), None);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_user_shell_prefers_env_shell() {
        // passwd says zsh, env says sh: env wins.
        let passwd = "me:x:1000:1000:Me:/home/me:/bin/zsh\n";
        let sh = which::which("sh").unwrap().to_string_lossy().into_owned();
        assert_eq!(resolve_user_shell(Some("sh"), passwd, 1000), Some(sh));
    }

    #[cfg(unix)]
    #[test]
    fn resolve_user_shell_uses_passwd_when_env_missing_or_uninstalled() {
        let passwd = "me:x:1000:1000:Me:/home/me:sh\n";
        let sh = which::which("sh").unwrap().to_string_lossy().into_owned();
        assert_eq!(resolve_user_shell(None, passwd, 1000), Some(sh.clone()));
        assert_eq!(
            resolve_user_shell(Some("/nonexistent/shell"), passwd, 1000),
            Some(sh.clone())
        );
        assert_eq!(resolve_user_shell(Some("  sh  "), passwd, 1000), Some(sh));
        assert_eq!(resolve_user_shell(None, "", 1000), None);
        assert_eq!(resolve_user_shell(Some("   "), "", 1000), None);
    }

    #[cfg(unix)]
    #[test]
    fn resolve_user_shell_skips_non_interactive_shells() {
        let nologin = "svc:x:1000:1000:Svc:/home/svc:/usr/sbin/nologin\n";
        let sh = which::which("sh").unwrap().to_string_lossy().into_owned();
        assert_eq!(resolve_user_shell(None, nologin, 1000), None);
        assert_eq!(resolve_user_shell(Some("/bin/false"), nologin, 1000), None);
        // A non-interactive env shell falls through to the passwd entry.
        let passwd = "me:x:1000:1000:Me:/home/me:sh\n";
        assert_eq!(
            resolve_user_shell(Some("/bin/false"), passwd, 1000),
            Some(sh)
        );
    }

    #[tokio::test]
    async fn ttl_expires_session() {
        let manager = TerminalManager::new(Duration::from_millis(100), Duration::from_millis(50));
        let session = manager
            .spawn(1, "t1".into(), Some("cat"), None)
            .await
            .expect("spawn cat");

        // Wait for the cleanup sweep to run more than once.
        tokio::time::sleep(Duration::from_millis(400)).await;

        assert!(manager.get(&session.id).await.is_none());
    }
}
