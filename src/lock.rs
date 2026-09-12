//! Single-instance advisory lock to prevent multiple Devinorium processes
//! from running against the same database.

use std::fs::File;
use std::path::{Path, PathBuf};

use anyhow::Result;

/// Holds an exclusive advisory lock on the instance lock file.
///
/// Field order matters on Windows: the guard must drop first so
/// `UnlockFileEx` runs while the file handle is still valid.
pub struct SingleInstance {
    #[cfg(windows)]
    _guard: platform::LockGuard,
    _file: File,
}

impl SingleInstance {
    /// Try to acquire the advisory lock for this process.
    ///
    /// If another process already holds the lock, this returns an error
    /// identifying the other process when possible.
    pub fn acquire(path: &Path) -> Result<Self> {
        platform::acquire(path)
    }
}

#[cfg(unix)]
mod platform {
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Seek, Write};
    use std::path::Path;

    use anyhow::{bail, Context, Result};
    use rustix::fs::{flock, FlockOperation};
    use rustix::process::{test_kill_process, Pid};

    use super::SingleInstance;

    pub fn acquire(path: &Path) -> Result<SingleInstance> {
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
                Ok(SingleInstance { _file: file })
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
}

#[cfg(windows)]
mod platform {
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Seek, Write};
    use std::os::windows::io::AsRawHandle;
    use std::path::Path;

    use anyhow::{bail, Context, Result};
    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_LOCK_VIOLATION, HANDLE};
    use windows_sys::Win32::Storage::FileSystem::{
        LockFileEx, UnlockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY,
    };
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::System::IO::OVERLAPPED;

    use super::SingleInstance;

    /// Byte offset the lock is taken on. Windows locks are mandatory and
    /// range-scoped, so locking a byte past where the PID lives keeps the PID
    /// readable for the "another instance is running" hint.
    const LOCK_OFFSET: u32 = 4096;

    /// Keeps the LockFileEx region held until dropped.
    pub struct LockGuard {
        handle: HANDLE,
    }

    impl Drop for LockGuard {
        fn drop(&mut self) {
            unsafe {
                let mut overlapped: OVERLAPPED = std::mem::zeroed();
                overlapped.Anonymous.Anonymous.Offset = LOCK_OFFSET;
                UnlockFileEx(self.handle, 0, 1, 0, &mut overlapped);
            }
        }
    }

    pub fn acquire(path: &Path) -> Result<SingleInstance> {
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

        let handle = file.as_raw_handle() as HANDLE;
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        overlapped.Anonymous.Anonymous.Offset = LOCK_OFFSET;
        let locked = unsafe {
            LockFileEx(
                handle,
                LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                0,
                1,
                0,
                &mut overlapped,
            )
        };

        if locked != 0 {
            write_pid(&mut file)?;
            return Ok(SingleInstance {
                _file: file,
                _guard: LockGuard { handle },
            });
        }

        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
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
        bail!("failed to acquire instance lock: {err}");
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
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle == 0 {
                return false;
            }
            let mut code = 0u32;
            let alive = GetExitCodeProcess(handle, &mut code) != 0 && code == 259; // STILL_ACTIVE
            CloseHandle(handle);
            alive
        }
    }
}

#[cfg(not(any(unix, windows)))]
mod platform {
    use std::path::Path;

    use anyhow::Result;

    use super::SingleInstance;

    pub fn acquire(_path: &Path) -> Result<SingleInstance> {
        anyhow::bail!("single-instance locking is not supported on this platform");
    }
}

/// Derive the lock-file path from a SQLite database URL.
///
/// Returns `None` for in-memory databases.
pub fn lock_path_from_db_url(db_url: &str) -> Option<PathBuf> {
    if crate::db::is_in_memory_url(db_url) {
        return None;
    }

    let rest = db_url.strip_prefix("sqlite:")?;
    let mut path_part = rest.split('?').next()?.to_string();

    if path_part.starts_with("//") {
        let without_leading = &path_part[2..];
        let idx = without_leading.find('/')?;
        path_part = without_leading[idx..].to_string();
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
            Some(PathBuf::from(
                "/home/calico/devinorium/data/devinorium.lock"
            ))
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
        assert!(
            result.is_err(),
            "should fail when another process holds the lock"
        );

        let _ = child.kill();
        let _ = child.wait();
    }
}
