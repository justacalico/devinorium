//! Single-instance advisory lock to prevent multiple Devinorium processes
//! from running against the same database.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use rustix::fs::{flock, FlockOperation};
use rustix::process::{test_kill_process, Pid};

/// Holds an exclusive advisory lock on the instance lock file.
pub struct SingleInstance {
    _file: File,
}

impl SingleInstance {
    /// Try to acquire the advisory lock for this process.
    ///
    /// If another process already holds the lock, this returns an error
    /// identifying the other process when possible.
    pub fn acquire(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let mut file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
            .with_context(|| format!("opening lock file at {}", path.display()))?;

        match flock(&file, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => {
                write_pid(&mut file)?;
                Ok(Self { _file: file })
            }
            Err(rustix::io::Errno::AGAIN) => {
                let other = read_pid(&mut file);
                let pid_hint = other
                    .and_then(|pid| is_process_alive(pid).then_some(pid))
                    .map(|pid| format!("; another instance is running with PID {pid}"))
                    .unwrap_or_else(|| "; another instance may already be running".to_string());
                bail!(
                    "database is locked by another Devinorium process{pid_hint}. \
                     Stop the other process or remove the lock file ({}) to continue",
                    path.display()
                );
            }
            Err(e) => bail!("failed to acquire instance lock: {e}"),
        }
    }
}

fn write_pid(file: &mut File) -> Result<()> {
    let pid = std::process::id();
    file.set_len(0)?;
    file.rewind()?;
    writeln!(file, "{pid}")?;
    file.sync_all()?;
    Ok(())
}

fn read_pid(file: &mut File) -> Option<u32> {
    let mut buf = String::new();
    file.rewind().ok()?;
    file.read_to_string(&mut buf).ok()?;
    buf.trim().parse().ok()
}

fn is_process_alive(pid: u32) -> bool {
    Pid::from_raw(pid as i32)
        .map(|p| test_kill_process(p).is_ok())
        .unwrap_or(false)
}

/// Derive the lock-file path from a SQLite database URL.
///
/// Returns `None` for in-memory databases.
pub fn lock_path_from_db_url(db_url: &str) -> Option<PathBuf> {
    if db_url == "sqlite::memory:" || db_url.starts_with("sqlite::memory:") {
        return None;
    }

    let rest = db_url.strip_prefix("sqlite:")?;
    let mut path_part = rest.split('?').next()?.to_string();

    if path_part.starts_with("//") {
        let without_leading = &path_part[2..];
        if let Some(idx) = without_leading.find('/') {
            path_part = without_leading[idx..].to_string();
        } else {
            return None;
        }
    }

    if path_part.is_empty() {
        return None;
    }

    let db_path = Path::new(&path_part);
    Some(db_path.with_extension("lock"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_path_parses_relative_db_url() {
        assert_eq!(
            lock_path_from_db_url("sqlite:data/devinorium.db?mode=rwc"),
            Some(PathBuf::from("data/devinorium.lock"))
        );
    }

    #[test]
    fn lock_path_parses_absolute_db_url() {
        assert_eq!(
            lock_path_from_db_url("sqlite:///home/calico/devinorium/data/devinorium.db"),
            Some(PathBuf::from("/home/calico/devinorium/data/devinorium.lock"))
        );
    }

    #[test]
    fn lock_path_returns_none_for_in_memory() {
        assert_eq!(lock_path_from_db_url("sqlite::memory:"), None);
    }

    #[test]
    fn lock_path_returns_none_for_invalid_url() {
        assert_eq!(lock_path_from_db_url("not-a-sqlite-url"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn single_instance_rejects_concurrent_process() {
        use std::fs::File;
        use std::process::{Command, Stdio};
        use std::thread;
        use std::time::{Duration, Instant};

        let tmp = tempfile::tempdir().unwrap();
        let lock = tmp.path().join("test.lock");
        let ready = tmp.path().join("ready");

        // Ensure the lock file exists so the flock command can open it.
        File::create(&lock).unwrap();

        let mut child = Command::new("flock")
            .arg("-x")
            .arg(&lock)
            .arg("-c")
            .arg(format!("touch {} && sleep 5", ready.display()))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("flock command should be available on Linux");

        // Wait until the child has actually acquired the lock.
        let start = Instant::now();
        while !ready.exists() {
            if start.elapsed() > Duration::from_secs(5) {
                let _ = child.kill();
                panic!("child did not acquire the lock in time");
            }
            thread::sleep(Duration::from_millis(50));
        }

        let result = SingleInstance::acquire(&lock);
        assert!(result.is_err(), "should fail when another process holds the lock");

        let _ = child.kill();
    }
}
