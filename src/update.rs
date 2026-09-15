//! Server self-update: check GitLab releases for a newer server binary,
//! download it, verify the published SHA-256, swap it in place, and restart
//! the process.
//!
//! Release binaries are published per platform as
//! `devinorium-<tag>-<platform>` next to a `SHA256SUMS.txt` covering every
//! asset. Only stable `vX.Y.Z` tags are considered; the moving `nightly`
//! release is ignored.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::providers::version::is_newer;

/// GitLab v4 API base for the project's releases endpoint.
const DEFAULT_API_BASE: &str = "https://gitlab.com/api/v4/projects/HttpAnimations%2Fdevinorium";
/// Public releases page, sent to the UI so it can link to the release.
const RELEASES_PAGE: &str = "https://gitlab.com/HttpAnimations/devinorium/-/releases";
/// The checksum manifest published with every release.
const CHECKSUMS_ASSET: &str = "SHA256SUMS.txt";
/// Delay between answering the apply request and re-executing, so the
/// response has time to reach the client before the process goes away.
const RESTART_DELAY: Duration = Duration::from_millis(750);
const API_TIMEOUT: Duration = Duration::from_secs(10);
/// The binary is tens of megabytes; the download gets a generous cap.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);
/// Refuse downloads beyond this size; the real binary is far smaller.
const MAX_BINARY_BYTES: u64 = 512 * 1024 * 1024;
/// Releases JSON and the checksums file are small; a hostile or broken
/// endpoint returning a giant body is refused rather than buffered.
const MAX_METADATA_BYTES: u64 = 16 * 1024 * 1024;
const RELEASES_PER_PAGE: u32 = 100;
const RELEASES_MAX_PAGES: u32 = 10;

#[derive(Debug, Error)]
pub enum UpdateError {
    #[error("an update is already in progress")]
    InProgress,
    #[error("no update is available")]
    NoUpdate,
    #[error("the latest release has no binary for this platform")]
    NoAsset,
    #[error("the release checksums do not cover this platform's binary")]
    ChecksumMissing,
    #[error("the downloaded binary does not match its published checksum")]
    ChecksumMismatch,
    #[error("this instance cannot be updated: {0:?}")]
    NotUpdatable(NotUpdatable),
    #[error("{0}")]
    Other(String),
}

impl UpdateError {
    fn other(e: impl std::fmt::Display) -> Self {
        Self::Other(e.to_string())
    }
}

/// Why self-update is unavailable, reported to the UI as a stable code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NotUpdatable {
    LocalMode,
    DevMode,
    UnsupportedPlatform,
}

/// Facts about the running instance that gate self-update.
#[derive(Debug, Clone, Copy)]
pub struct UpdateEnv {
    /// Bundled desktop server; the app package owns the binary.
    pub local_mode: bool,
    /// `--dev`/`--local` throwaway instance on a random port.
    pub dev_mode: bool,
}

impl UpdateEnv {
    pub fn not_updatable(&self) -> Option<NotUpdatable> {
        if self.local_mode {
            return Some(NotUpdatable::LocalMode);
        }
        if self.dev_mode {
            return Some(NotUpdatable::DevMode);
        }
        if platform_asset_suffix().is_none() {
            return Some(NotUpdatable::UnsupportedPlatform);
        }
        None
    }
}

#[derive(Debug, Serialize)]
pub struct UpdateCheck {
    pub current_version: String,
    pub latest_version: Option<String>,
    pub latest_tag: Option<String>,
    pub release_url: Option<String>,
    pub asset_name: Option<String>,
    pub update_available: bool,
    pub updatable: bool,
    pub reason: Option<NotUpdatable>,
}

/// The staged result of [`UpdateService::apply`]: the new binary is in
/// place (unix) or parked next to the executable for the swap helper
/// (windows). Restarting is left to the caller via [`schedule_restart`].
#[derive(Debug)]
pub struct AppliedUpdate {
    pub version: String,
    pub tag: String,
    pub exe: PathBuf,
    pub staged: PathBuf,
}

#[derive(Debug, Deserialize)]
struct ReleaseEntry {
    /// Missing tags deserialize as `""` and are skipped as non-semver.
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    assets: ReleaseAssets,
}

#[derive(Debug, Default, Deserialize)]
struct ReleaseAssets {
    #[serde(default)]
    links: Vec<ReleaseLink>,
}

#[derive(Debug, Deserialize)]
struct ReleaseLink {
    name: String,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    direct_asset_url: Option<String>,
}

/// The shared service used by the API. `api_base` is `None` here so the
/// `DEVINORIUM_UPDATE_API_URL` override is honored on every call.
pub struct UpdateService {
    api_base: Option<String>,
    updating: AtomicBool,
}

static SERVICE: UpdateService = UpdateService {
    api_base: None,
    updating: AtomicBool::new(false),
};

/// The process-wide update service.
pub fn service() -> &'static UpdateService {
    &SERVICE
}

impl UpdateService {
    /// A service pinned to an explicit API base, for tests and mirrors.
    pub fn with_base_url(api_base: impl Into<String>) -> Self {
        Self {
            api_base: Some(api_base.into()),
            updating: AtomicBool::new(false),
        }
    }

    pub fn is_updating(&self) -> bool {
        self.updating.load(Ordering::SeqCst)
    }

    /// The releases API base. `DEVINORIUM_UPDATE_API_URL` overrides it for
    /// mirrors; plaintext http is only accepted for loopback hosts (local
    /// mirrors and tests) — a remote http base would let an on-path
    /// attacker substitute release metadata, checksums, and binary.
    fn api_base(&self) -> Result<String> {
        let base = match &self.api_base {
            Some(b) => b.clone(),
            None => std::env::var("DEVINORIUM_UPDATE_API_URL")
                .ok()
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| DEFAULT_API_BASE.to_string()),
        };
        let parsed = reqwest::Url::parse(&base).context("invalid update API base URL")?;
        match parsed.scheme() {
            "https" => Ok(base),
            "http" if is_loopback_host(parsed.host_str()) => Ok(base),
            _ => anyhow::bail!(
                "update API base must be https (loopback http is allowed for local mirrors)"
            ),
        }
    }

    /// True when the API base is a loopback http URL; only then are plain
    /// http asset URLs acceptable, and only to loopback hosts.
    fn insecure_http_ok(&self) -> bool {
        self.api_base()
            .ok()
            .and_then(|b| reqwest::Url::parse(&b).ok())
            .map(|u| u.scheme() == "http" && is_loopback_host(u.host_str()))
            .unwrap_or(false)
    }

    fn client(timeout: Duration) -> reqwest::Client {
        reqwest::Client::builder()
            .user_agent(concat!("devinorium/", env!("CARGO_PKG_VERSION")))
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                let url = attempt.url();
                if url.scheme() == "https" || is_loopback_host(url.host_str()) {
                    attempt.follow()
                } else {
                    attempt.stop()
                }
            }))
            .build()
            .expect("reqwest client")
    }

    /// Check the releases feed and compare the newest stable tag with the
    /// running version. Instances that cannot self-update short-circuit
    /// without touching the network. Other failures bubble up as errors so
    /// the UI can tell "check failed" from "up to date".
    pub async fn check(&self, env: UpdateEnv) -> Result<UpdateCheck> {
        let current_version = env!("CARGO_PKG_VERSION").to_string();
        if let Some(reason) = env.not_updatable() {
            return Ok(UpdateCheck {
                current_version,
                latest_version: None,
                latest_tag: None,
                release_url: None,
                asset_name: None,
                update_available: false,
                updatable: false,
                reason: Some(reason),
            });
        }

        let Some(latest) = self.latest_release().await? else {
            return Ok(UpdateCheck {
                current_version,
                latest_version: None,
                latest_tag: None,
                release_url: None,
                asset_name: None,
                update_available: false,
                updatable: true,
                reason: None,
            });
        };

        let latest_version = latest.tag_name.trim_start_matches('v').to_string();
        // An update only counts when the release actually carries a binary
        // for this platform; otherwise apply would fail later anyway.
        let asset_name = platform_asset_suffix()
            .map(|suffix| asset_name(&latest.tag_name, suffix))
            .filter(|name| find_asset_url(&latest, name).is_some());
        let update_available = is_newer(&latest.tag_name, &current_version) && asset_name.is_some();

        Ok(UpdateCheck {
            current_version,
            latest_version: Some(latest_version),
            release_url: Some(format!("{RELEASES_PAGE}/{}", latest.tag_name)),
            latest_tag: Some(latest.tag_name),
            asset_name,
            update_available,
            updatable: true,
            reason: None,
        })
    }

    /// Download the newest stable release binary for this platform, verify
    /// it against the published checksums, and move it into place. On unix
    /// the staged file replaces `exe_path` directly; on windows it stays
    /// parked next to it for the swap helper. Either way the caller decides
    /// when to restart via [`schedule_restart`].
    ///
    /// The in-progress flag stays set on success because the process is
    /// about to be replaced; it is cleared again on failure. The `env`
    /// guard lives here too so no caller can update a bundled or dev
    /// instance by forgetting to check first.
    pub async fn apply(
        &self,
        env: UpdateEnv,
        exe_path: &Path,
    ) -> Result<AppliedUpdate, UpdateError> {
        if let Some(reason) = env.not_updatable() {
            return Err(UpdateError::NotUpdatable(reason));
        }
        if self.updating.swap(true, Ordering::SeqCst) {
            return Err(UpdateError::InProgress);
        }
        let guard = UpdatingGuard(&self.updating);
        let result = self.apply_inner(exe_path).await;
        if result.is_ok() {
            std::mem::forget(guard);
        }
        result
    }

    async fn apply_inner(&self, exe_path: &Path) -> Result<AppliedUpdate, UpdateError> {
        let current_version = env!("CARGO_PKG_VERSION");
        let suffix = platform_asset_suffix().ok_or(UpdateError::NoAsset)?;
        let release = self
            .latest_release()
            .await
            .map_err(UpdateError::other)?
            .ok_or(UpdateError::NoUpdate)?;
        if !is_newer(&release.tag_name, current_version) {
            return Err(UpdateError::NoUpdate);
        }

        // `/proc/self/exe` reports `name (deleted)` when the running binary
        // was unlinked; writing to the normalized path self-heals the
        // install instead of creating a stray `name (deleted)` file.
        let exe_path = normalize_exe_path(exe_path);

        let asset = asset_name(&release.tag_name, suffix);
        let asset_url = find_asset_url(&release, &asset).ok_or(UpdateError::NoAsset)?;
        let sums_url =
            find_asset_url(&release, CHECKSUMS_ASSET).ok_or(UpdateError::ChecksumMissing)?;

        // The release JSON decides where the binary and checksums come
        // from. Only fetch https targets (plus loopback http when the API
        // base itself is a local mirror) so a hostile feed cannot turn the
        // updater into an arbitrary fetcher.
        let insecure_ok = self.insecure_http_ok();
        for url in [&asset_url, &sums_url] {
            if !allowed_url(url, insecure_ok) {
                return Err(UpdateError::other(format!(
                    "refusing non-https release asset URL: {url}"
                )));
            }
        }

        let staged = staging_path(&exe_path);
        let download_result = async {
            self.download(&asset_url, &staged).await?;
            self.verify_checksum(&staged, &asset, &sums_url).await
        }
        .await;
        if let Err(e) = download_result {
            let _ = tokio::fs::remove_file(&staged).await;
            return Err(e);
        }

        // Unix lets a running binary's path be replaced by rename; the old
        // image keeps its inode until exec swaps in the new one. Windows
        // refuses to touch a loaded executable, so the staged file is left
        // for the helper to move once this process exits. The fresh inode
        // drops file capabilities, ACLs, and SELinux labels; an install
        // that relies on setcap to bind low ports must re-apply them.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))
                .await
                .map_err(UpdateError::other)?;
            if let Err(e) = tokio::fs::rename(&staged, &exe_path).await {
                let _ = tokio::fs::remove_file(&staged).await;
                return Err(UpdateError::other(format!(
                    "cannot replace {}: {e}",
                    exe_path.display()
                )));
            }
            // The binary was fsynced; sync the directory too so the new
            // entry survives a power loss before the restart.
            if let Some(parent) = exe_path.parent() {
                if let Ok(dir) = tokio::fs::File::open(parent).await {
                    let _ = dir.sync_all().await;
                }
            }
        }

        Ok(AppliedUpdate {
            version: release.tag_name.trim_start_matches('v').to_string(),
            tag: release.tag_name,
            exe: exe_path,
            staged,
        })
    }

    /// The newest stable release. Non-semver tags (nightly) are skipped.
    async fn latest_release(&self) -> Result<Option<ReleaseEntry>> {
        let base = self.api_base()?;
        let client = Self::client(API_TIMEOUT);
        let mut best: Option<ReleaseEntry> = None;

        for page in 1..=RELEASES_MAX_PAGES {
            let url = format!(
                "{base}/releases?per_page={RELEASES_PER_PAGE}&order_by=released_at&sort=desc&page={page}"
            );
            let body = get_body(&client, &url, MAX_METADATA_BYTES).await?;
            let releases: Vec<ReleaseEntry> =
                serde_json::from_slice(&body).context("decoding releases response")?;
            let count = releases.len();
            for release in releases {
                if version_segments(&release.tag_name).is_none() {
                    continue;
                }
                let newer = match &best {
                    None => true,
                    Some(b) => is_newer(&release.tag_name, &b.tag_name),
                };
                if newer {
                    best = Some(release);
                }
            }
            if count < RELEASES_PER_PAGE as usize {
                break;
            }
        }

        Ok(best)
    }

    /// Stream a release asset to disk, refusing oversize payloads.
    async fn download(&self, url: &str, dest: &Path) -> Result<(), UpdateError> {
        use tokio::io::AsyncWriteExt;

        let mut resp = Self::client(DOWNLOAD_TIMEOUT)
            .get(url)
            .send()
            .await
            .and_then(|r| r.error_for_status())
            .map_err(|e| UpdateError::other(format!("GET {url} failed: {e}")))?;
        if let Some(len) = resp.content_length() {
            if len > MAX_BINARY_BYTES {
                return Err(UpdateError::other("release asset is too large"));
            }
        }

        // create_new refuses to follow a pre-planted symlink and turns a
        // stale staged file into an explicit error.
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(dest)
            .await
            .map_err(|e| UpdateError::other(format!("cannot write {}: {e}", dest.display())))?;
        let mut written = 0u64;
        let mut stream_result: Result<(), UpdateError> = Ok(());
        while let Some(chunk) = resp.chunk().await.map_err(UpdateError::other)? {
            written += chunk.len() as u64;
            if written > MAX_BINARY_BYTES {
                stream_result = Err(UpdateError::other("release asset is too large"));
                break;
            }
            if let Err(e) = file.write_all(&chunk).await {
                stream_result = Err(UpdateError::other(format!(
                    "cannot write {}: {e}",
                    dest.display()
                )));
                break;
            }
        }
        drop(file);
        stream_result?;
        file_sync(dest).await.map_err(UpdateError::other)
    }

    /// Compare the staged binary with its published SHA-256. Every release
    /// publishes `SHA256SUMS.txt`, so a missing checksums asset or an entry
    /// gap is fatal rather than a reason to skip verification.
    async fn verify_checksum(
        &self,
        staged: &Path,
        asset: &str,
        sums_url: &str,
    ) -> Result<(), UpdateError> {
        let body = get_body(&Self::client(API_TIMEOUT), sums_url, MAX_METADATA_BYTES)
            .await
            .map_err(UpdateError::other)?;
        let text = String::from_utf8_lossy(&body);

        let expected = parse_sha256sums(&text)
            .into_iter()
            .find(|(name, _)| name == asset)
            .map(|(_, sum)| sum)
            .ok_or(UpdateError::ChecksumMissing)?;
        let actual = sha256_file(staged).await.map_err(UpdateError::other)?;
        if !actual.eq_ignore_ascii_case(&expected) {
            return Err(UpdateError::ChecksumMismatch);
        }
        Ok(())
    }
}

/// The platform suffix used in release asset names, or `None` when CI does
/// not publish a server binary for this platform.
pub fn platform_asset_suffix() -> Option<&'static str> {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    return Some("linux-x86_64");
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    return Some("windows-x86_64.exe");
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    return Some("macos-arm64");
    #[allow(unreachable_code)]
    None
}

/// `devinorium-v0.78.0-linux-x86_64` style asset names used by CI.
fn asset_name(tag: &str, suffix: &str) -> String {
    format!("devinorium-{tag}-{suffix}")
}

/// The download URL for a named release asset, preferring the direct
/// (non-API) link GitLab reports for package-registry files.
fn find_asset_url(release: &ReleaseEntry, name: &str) -> Option<String> {
    release
        .assets
        .links
        .iter()
        .find(|l| l.name == name)
        .and_then(|l| l.direct_asset_url.clone().or_else(|| l.url.clone()))
}

/// `devinorium.update-<pid>` next to the executable, so the swap is a
/// same-filesystem rename.
fn staging_path(exe_path: &Path) -> PathBuf {
    let name = exe_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "devinorium".to_string());
    exe_path.with_file_name(format!("{name}.update-{}", std::process::id()))
}

/// Linux reports `name (deleted)` for an executable that was unlinked
/// while running; normalize back to the real install path.
fn normalize_exe_path(exe: &Path) -> PathBuf {
    let Some(name) = exe.file_name().and_then(|n| n.to_str()) else {
        return exe.to_path_buf();
    };
    match name.strip_suffix(" (deleted)") {
        Some(real) => exe.with_file_name(real),
        None => exe.to_path_buf(),
    }
}

/// Localhost is the only place plaintext http is acceptable.
fn is_loopback_host(host: Option<&str>) -> bool {
    matches!(host, Some("localhost" | "127.0.0.1" | "::1" | "[::1]"))
}

/// Whether a release-asset URL may be fetched. https is always fine;
/// plain http is only allowed to loopback hosts and only when the
/// configured API base is itself a loopback http mirror.
fn allowed_url(url: &str, insecure_http_ok: bool) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url) else {
        return false;
    };
    match parsed.scheme() {
        "https" => true,
        "http" => insecure_http_ok && is_loopback_host(parsed.host_str()),
        _ => false,
    }
}

/// GET `url` into memory, refusing bodies over `cap`. Used for release
/// metadata where `.json()`/`.text()` would buffer without a limit.
async fn get_body(client: &reqwest::Client, url: &str, cap: u64) -> Result<Vec<u8>> {
    let mut resp = client
        .get(url)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .with_context(|| format!("GET {url} failed"))?;
    if resp.content_length().is_some_and(|l| l > cap) {
        anyhow::bail!("GET {url}: response exceeds {cap} bytes");
    }
    let mut buf = Vec::new();
    while let Some(chunk) = resp.chunk().await? {
        buf.extend_from_slice(&chunk);
        if buf.len() as u64 > cap {
            anyhow::bail!("GET {url}: response exceeds {cap} bytes");
        }
    }
    Ok(buf)
}

/// Resets the in-progress flag on drop so a panic mid-apply cannot wedge
/// the updater into permanent 409s. `apply` forgets the guard on success
/// because the flag is meant to stay set until the process restarts.
struct UpdatingGuard<'a>(&'a AtomicBool);

impl Drop for UpdatingGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// Numeric dotted segments of a stable tag, or `None` for anything else:
/// `nightly`, prereleases (`v1.2.3-rc.1`), and build metadata
/// (`v1.2.3+build`) are all rejected so only plain `vX.Y.Z` releases are
/// ever offered or installed.
fn version_segments(tag: &str) -> Option<Vec<u64>> {
    let tag = tag.trim().trim_start_matches('v');
    if tag.is_empty() || tag.contains(['-', '+']) {
        return None;
    }
    tag.split('.')
        .map(|p| p.parse::<u64>().ok())
        .collect::<Option<Vec<u64>>>()
}

/// Parse `sha256sum` output lines (`<hex>  <name>`) into (name, sum) pairs.
fn parse_sha256sums(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let (sum, name) = line.split_once(char::is_whitespace)?;
            let name = name.trim().trim_start_matches('*');
            if name.is_empty() {
                return None;
            }
            Some((name.to_string(), sum.trim().to_string()))
        })
        .collect()
}

async fn sha256_file(path: &Path) -> Result<String> {
    use tokio::io::AsyncReadExt;

    let mut file = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

async fn file_sync(path: &Path) -> Result<()> {
    let file = tokio::fs::OpenOptions::new().write(true).open(path).await?;
    file.sync_all().await?;
    Ok(())
}

/// Restart into the staged update after [`RESTART_DELAY`], giving the
/// in-flight HTTP response time to flush.
pub fn schedule_restart(exe: PathBuf, staged: PathBuf) {
    tokio::spawn(async move {
        tokio::time::sleep(RESTART_DELAY).await;
        restart_process(&exe, &staged);
    });
}

/// Hand the process off to the new binary. Never returns.
#[cfg(unix)]
fn restart_process(exe: &Path, _staged: &Path) -> ! {
    use std::os::unix::process::CommandExt;

    // The staged file already replaced `exe`; exec keeps the PID, env and
    // cwd while sockets close on exec, letting the new image rebind.
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let err = std::process::Command::new(exe).args(&args).exec();
    tracing::error!("re-exec into updated binary failed: {err}");
    std::process::exit(1);
}

/// A running Windows image cannot be replaced, so a detached helper script
/// waits for this process to exit, moves the staged binary over the exe,
/// and starts it again.
#[cfg(windows)]
fn restart_process(exe: &Path, staged: &Path) -> ! {
    match spawn_swap_helper(exe, staged) {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            tracing::error!("failed to spawn update helper: {e}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn spawn_swap_helper(exe: &Path, staged: &Path) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    use std::process::Stdio;

    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const DETACHED_PROCESS: u32 = 0x0000_0008;

    // `%` expands inside batch files and newlines split commands, so any
    // interpolated string containing them would corrupt the script.
    let batch_safe = |s: &str| !s.chars().any(|c| matches!(c, '%' | '\r' | '\n'));
    let exe_s = exe.to_string_lossy();
    let staged_s = staged.to_string_lossy();
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    if !batch_safe(&exe_s) || !batch_safe(&staged_s) || args.iter().any(|a| !batch_safe(a)) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path or argument is not safe to embed in a batch file",
        ));
    }
    let quoted: Vec<String> = args
        .iter()
        .map(|a| format!("\"{}\"", a.replace('"', "\"\"")))
        .collect();

    let ext = staged.extension().unwrap_or_default().to_string_lossy();
    let script = staged.with_extension(format!("{ext}.cmd"));
    // `move` retries for up to ~30s so a slow exit or a scanner holding
    // the old image does not leave the server coming back un-updated.
    let contents = format!(
        "@echo off\r\n\
         set /a tries=0\r\n\
         :wait\r\n\
         ping 127.0.0.1 -n 2 >nul\r\n\
         move /y \"{staged_s}\" \"{exe_s}\" >nul 2>&1\r\n\
         if not errorlevel 1 goto ok\r\n\
         set /a tries+=1\r\n\
         if %tries% lss 30 goto wait\r\n\
         exit /b 1\r\n\
         :ok\r\n\
         start \"\" \"{exe_s}\" {}\r\n\
         del \"%~f0\" >nul 2>&1\r\n",
        quoted.join(" ")
    );
    std::fs::write(&script, contents)?;

    std::process::Command::new("cmd")
        .arg("/c")
        .arg(&script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
        .spawn()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::IntoFuture;

    /// A normal self-hosted instance: not bundled, not a dev server.
    const TEST_ENV: UpdateEnv = UpdateEnv {
        local_mode: false,
        dev_mode: false,
    };

    fn release(tag: &str, assets: &[(&str, &str)]) -> serde_json::Value {
        serde_json::json!({
            "tag_name": tag,
            "assets": {
                "links": assets
                    .iter()
                    .map(|(name, url)| serde_json::json!({
                        "name": name,
                        "url": url,
                        "direct_asset_url": url,
                    }))
                    .collect::<Vec<_>>(),
            },
        })
    }

    async fn mock_releases_server(body: serde_json::Value) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = axum::Router::new().route(
            "/releases",
            axum::routing::get(move || {
                let body = body.clone();
                async move { axum::Json(body) }
            }),
        );
        tokio::spawn(axum::serve(listener, app).into_future());
        format!("http://127.0.0.1:{port}")
    }

    #[test]
    fn version_segments_accepts_semver_and_skips_nightly() {
        assert_eq!(version_segments("v1.2.3"), Some(vec![1, 2, 3]));
        assert_eq!(version_segments("1.2.3"), Some(vec![1, 2, 3]));
        assert_eq!(version_segments("nightly"), None);
        // Prerelease and build-metadata tags are not stable releases.
        assert_eq!(version_segments("v1.2.3-rc.1"), None);
        assert_eq!(version_segments("v1.2.3+build"), None);
        assert_eq!(version_segments(""), None);
    }

    #[test]
    fn allowed_url_gates_scheme_and_host() {
        assert!(allowed_url("https://gitlab.com/x/bin", false));
        assert!(allowed_url("https://anything.example/bin", false));
        assert!(!allowed_url("http://169.254.169.254/meta", false));
        assert!(!allowed_url("http://127.0.0.1:9/bin", false));
        assert!(allowed_url("http://127.0.0.1:9/bin", true));
        assert!(!allowed_url("file:///etc/passwd", true));
        assert!(!allowed_url("not a url", true));
    }

    #[test]
    fn normalize_exe_path_strips_deleted_suffix() {
        assert_eq!(
            normalize_exe_path(Path::new("/usr/bin/devinorium (deleted)")),
            PathBuf::from("/usr/bin/devinorium")
        );
        assert_eq!(
            normalize_exe_path(Path::new("/usr/bin/devinorium")),
            PathBuf::from("/usr/bin/devinorium")
        );
    }

    #[test]
    fn asset_name_uses_tag_and_suffix() {
        assert_eq!(
            asset_name("v0.78.0", "linux-x86_64"),
            "devinorium-v0.78.0-linux-x86_64"
        );
        assert_eq!(
            asset_name("0.78.0", "windows-x86_64.exe"),
            "devinorium-0.78.0-windows-x86_64.exe"
        );
    }

    #[test]
    fn parse_sha256sums_reads_standard_lines() {
        let text = "abc123  devinorium-v1-linux-x86_64\n\
                    def456 *devinorium-v1-windows-x86_64.exe\n\
                    \n\
                    bad-line-without-name\n";
        let sums = parse_sha256sums(text);
        assert_eq!(
            sums,
            vec![
                ("devinorium-v1-linux-x86_64".into(), "abc123".into()),
                ("devinorium-v1-windows-x86_64.exe".into(), "def456".into()),
            ]
        );
    }

    #[tokio::test]
    async fn sha256_file_hashes_contents() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bin");
        tokio::fs::write(&path, b"hello").await.unwrap();
        let sum = sha256_file(&path).await.unwrap();
        assert_eq!(
            sum,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[tokio::test]
    async fn check_reports_update_for_newer_stable_tag() {
        let base = mock_releases_server(serde_json::json!([
            release("nightly", &[]),
            release(
                "v9999.0.0",
                &[("devinorium-v9999.0.0-linux-x86_64", "http://x/bin")]
            ),
            release("v0.0.1", &[]),
        ]))
        .await;
        let svc = UpdateService::with_base_url(base);
        let check = svc
            .check(UpdateEnv {
                local_mode: false,
                dev_mode: false,
            })
            .await
            .unwrap();
        assert_eq!(check.latest_tag.as_deref(), Some("v9999.0.0"));
        assert!(check.update_available);
        assert!(check.updatable);
        assert_eq!(
            check.release_url.as_deref(),
            Some("https://gitlab.com/HttpAnimations/devinorium/-/releases/v9999.0.0")
        );
    }

    #[tokio::test]
    async fn check_reports_up_to_date() {
        let base = mock_releases_server(serde_json::json!([release("v0.0.1", &[]),])).await;
        let svc = UpdateService::with_base_url(base);
        let check = svc
            .check(UpdateEnv {
                local_mode: false,
                dev_mode: false,
            })
            .await
            .unwrap();
        assert_eq!(check.latest_tag.as_deref(), Some("v0.0.1"));
        assert!(!check.update_available);
        assert_eq!(check.asset_name, None);
    }

    #[tokio::test]
    async fn check_flags_local_and_dev_mode() {
        let base = mock_releases_server(serde_json::json!([release("v9999.0.0", &[]),])).await;
        let svc = UpdateService::with_base_url(base);
        let local = svc
            .check(UpdateEnv {
                local_mode: true,
                dev_mode: false,
            })
            .await
            .unwrap();
        assert_eq!(local.reason, Some(NotUpdatable::LocalMode));
        assert!(!local.updatable);
        // Instances that cannot update do not hit the releases feed.
        assert_eq!(local.latest_tag, None);

        let dev = svc
            .check(UpdateEnv {
                local_mode: false,
                dev_mode: true,
            })
            .await
            .unwrap();
        assert_eq!(dev.reason, Some(NotUpdatable::DevMode));
    }

    /// A mock releases server: `GET /releases` lists one release pointing
    /// at `GET /bin` (the staged binary) and `GET /sums` (its checksums).
    async fn staged_mock_server(binary: Vec<u8>, sums: String) -> (String, tempfile::TempDir) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");
        let suffix = platform_asset_suffix().expect("test platform publishes a binary");
        let asset = asset_name("v9999.0.0", suffix);
        let bin_url = format!("{base}/bin");
        let sums_url = format!("{base}/sums");
        let releases = serde_json::json!([release(
            "v9999.0.0",
            &[
                (asset.as_str(), bin_url.as_str()),
                (CHECKSUMS_ASSET, sums_url.as_str()),
            ],
        )]);
        let app = axum::Router::new()
            .route(
                "/releases",
                axum::routing::get(move || {
                    let releases = releases.clone();
                    async move { axum::Json(releases) }
                }),
            )
            .route(
                "/bin",
                axum::routing::get(move || {
                    let binary = binary.clone();
                    async move { binary }
                }),
            )
            .route(
                "/sums",
                axum::routing::get(move || {
                    let sums = sums.clone();
                    async move { sums }
                }),
            );
        tokio::spawn(axum::serve(listener, app).into_future());
        (base, tempfile::tempdir().unwrap())
    }

    #[tokio::test]
    async fn check_skips_prerelease_tags() {
        let base = mock_releases_server(serde_json::json!([
            release("v9999.0.0-rc.1", &[]),
            release("v0.0.1", &[]),
        ]))
        .await;
        let svc = UpdateService::with_base_url(base);
        let check = svc.check(TEST_ENV).await.unwrap();
        assert_eq!(check.latest_tag.as_deref(), Some("v0.0.1"));
        assert!(!check.update_available);
    }

    #[tokio::test]
    async fn check_reports_no_update_when_platform_asset_missing() {
        let base = mock_releases_server(serde_json::json!([release(
            "v9999.0.0",
            &[(CHECKSUMS_ASSET, "http://x/sums")],
        )]))
        .await;
        let svc = UpdateService::with_base_url(base);
        let check = svc.check(TEST_ENV).await.unwrap();
        assert_eq!(check.latest_tag.as_deref(), Some("v9999.0.0"));
        assert!(!check.update_available);
        assert_eq!(check.asset_name, None);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_downloads_verifies_and_replaces_exe() {
        let Some(suffix) = platform_asset_suffix() else {
            return;
        };
        let binary = b"new-binary".to_vec();
        let sha = format!("{:x}", Sha256::digest(&binary));
        let asset = asset_name("v9999.0.0", suffix);
        let (base, dir) = staged_mock_server(binary.clone(), format!("{sha}  {asset}\n")).await;
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let applied = svc.apply(TEST_ENV, &exe).await.unwrap();
        assert_eq!(applied.tag, "v9999.0.0");
        assert_eq!(std::fs::read(&exe).unwrap(), binary);
        assert!(!applied.staged.exists(), "staged file was renamed over exe");
        assert!(svc.is_updating());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_checksum_mismatch() {
        let Some(suffix) = platform_asset_suffix() else {
            return;
        };
        let binary = b"tampered".to_vec();
        let asset = asset_name("v9999.0.0", suffix);
        let (base, dir) = staged_mock_server(binary, format!("deadbeef  {asset}\n")).await;
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::ChecksumMismatch));
        // The exe is untouched and the staged file is cleaned up.
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
        assert!(!svc.is_updating());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_missing_checksum_entry() {
        if platform_asset_suffix().is_none() {
            return;
        }
        let (base, dir) = staged_mock_server(b"bin".to_vec(), "abc  other-file\n".into()).await;
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::ChecksumMissing));
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_missing_checksums_asset() {
        if platform_asset_suffix().is_none() {
            return;
        }
        // The release has the binary but no SHA256SUMS link at all.
        let suffix = platform_asset_suffix().unwrap();
        let base = mock_releases_server(serde_json::json!([release(
            "v9999.0.0",
            &[(asset_name("v9999.0.0", suffix).as_str(), "http://x/bin")],
        )]))
        .await;
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::ChecksumMissing));
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_non_https_asset_url() {
        let Some(suffix) = platform_asset_suffix() else {
            return;
        };
        // Even with a loopback http API base, asset URLs must stay on
        // loopback; a remote http target is refused before any download.
        let asset = asset_name("v9999.0.0", suffix);
        let base = mock_releases_server(serde_json::json!([release(
            "v9999.0.0",
            &[
                (asset.as_str(), "http://192.0.2.1/bin"),
                (CHECKSUMS_ASSET, "http://192.0.2.1/sums"),
            ],
        )]))
        .await;
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::Other(_)));
        assert_eq!(std::fs::read(&exe).unwrap(), b"old-binary");
    }

    #[tokio::test]
    async fn apply_refuses_local_and_dev_env() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();
        let svc = UpdateService::with_base_url("http://127.0.0.1:1");

        let err = svc
            .apply(
                UpdateEnv {
                    local_mode: true,
                    dev_mode: false,
                },
                &exe,
            )
            .await
            .unwrap_err();
        assert!(matches!(
            err,
            UpdateError::NotUpdatable(NotUpdatable::LocalMode)
        ));

        let err = svc
            .apply(
                UpdateEnv {
                    local_mode: false,
                    dev_mode: true,
                },
                &exe,
            )
            .await
            .unwrap_err();
        assert!(matches!(
            err,
            UpdateError::NotUpdatable(NotUpdatable::DevMode)
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_when_already_latest() {
        let base = mock_releases_server(serde_json::json!([release("v0.0.1", &[])])).await;
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::NoUpdate));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn apply_rejects_second_concurrent_run() {
        let Some(suffix) = platform_asset_suffix() else {
            return;
        };
        let binary = b"new-binary".to_vec();
        let sha = format!("{:x}", Sha256::digest(&binary));
        let asset = asset_name("v9999.0.0", suffix);
        let (base, dir) = staged_mock_server(binary, format!("{sha}  {asset}\n")).await;
        let exe = dir.path().join("devinorium");
        std::fs::write(&exe, b"old-binary").unwrap();

        let svc = UpdateService::with_base_url(base);
        svc.updating.store(true, Ordering::SeqCst);
        let err = svc.apply(TEST_ENV, &exe).await.unwrap_err();
        assert!(matches!(err, UpdateError::InProgress));
    }
}
