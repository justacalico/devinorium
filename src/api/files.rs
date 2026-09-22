//! File manager API routes.
//!
//! Paths are resolved relative to the active project (if any) or the user's
//! home directory. Absolute paths are accepted, and path traversal via `..`
//! is prevented by canonicalization. Paths containing `.git` or
//! `.devinorium-attachments` are rejected and never listed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, Weak};

use once_cell::sync::Lazy;
use tokio::sync::Mutex;

static FILE_WRITE_LOCKS: Lazy<StdMutex<HashMap<String, Weak<Mutex<()>>>>> =
    Lazy::new(|| StdMutex::new(HashMap::new()));

fn file_write_lock(target: &Path) -> Arc<Mutex<()>> {
    let key = target.to_string_lossy().to_string();
    let mut map = FILE_WRITE_LOCKS.lock().unwrap();
    if let Some(lock) = map.get(&key).and_then(Weak::upgrade) {
        return lock;
    }
    // Entries expire once no writer holds them; sweep the dead ones so the
    // map does not grow without bound across many distinct paths.
    if map.len() >= 4096 {
        map.retain(|_, v| v.strong_count() > 0);
    }
    let lock = Arc::new(Mutex::new(()));
    map.insert(key, Arc::downgrade(&lock));
    lock
}

/// Pin a canonical directory's ancestor chain so a component cannot be
/// swapped for a symlink between the scope check and the delete. On Linux
/// every component is opened relative to the previous fd with O_NOFOLLOW
/// and the returned path goes through /proc/self/fd, so the removal stays
/// anchored to the inodes that were verified. On systems without procfs we
/// fall back to re-checking that every ancestor is still a real directory
/// at call time — a swap then fails the delete instead of redirecting it.
#[cfg(target_os = "linux")]
fn pin_delete_dir(
    canon_parent: &Path,
) -> std::io::Result<(Option<rustix::fd::OwnedFd>, PathBuf)> {
    use rustix::fs::{openat, Mode, OFlags};
    use std::os::unix::io::AsRawFd;

    if !Path::new("/proc/self/fd").is_dir() {
        return real_dir_parent(canon_parent).map(|p| (None, p));
    }
    let flags = OFlags::PATH | OFlags::NOFOLLOW | OFlags::DIRECTORY | OFlags::CLOEXEC;
    let mut fd = openat(rustix::fs::CWD, "/", flags, Mode::empty())?;
    for comp in canon_parent.components() {
        let std::path::Component::Normal(name) = comp else {
            continue;
        };
        fd = openat(&fd, name, flags, Mode::empty())?;
    }
    let pinned = PathBuf::from(format!("/proc/self/fd/{}", fd.as_raw_fd()));
    Ok((Some(fd), pinned))
}

#[cfg(not(target_os = "linux"))]
fn pin_delete_dir(canon_parent: &Path) -> std::io::Result<(Option<()>, PathBuf)> {
    real_dir_parent(canon_parent).map(|p| (None, p))
}

#[cfg(unix)]
fn real_dir_parent(canon_parent: &Path) -> std::io::Result<PathBuf> {
    for anc in canon_parent.ancestors() {
        let meta = std::fs::symlink_metadata(anc)?;
        if !meta.is_dir() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "path component is not a directory",
            ));
        }
    }
    Ok(canon_parent.to_path_buf())
}

#[cfg(windows)]
fn real_dir_parent(canon_parent: &Path) -> std::io::Result<PathBuf> {
    Ok(canon_parent.to_path_buf())
}

pub(crate) fn multipart_err(e: axum::extract::multipart::MultipartError) -> Response {
    (
        e.status(),
        Json(crate::api::ApiError::new(e.body_text())),
    )
        .into_response()
}

use axum::extract::{Multipart, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use chrono::DateTime;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::auth::session::CurrentUser;
use crate::api::scope;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/files", get(list_dir).post(upload))
        .route("/api/files/content", get(read_file).put(write_file))
        .route("/api/files/dir", post(mkdir))
        .route("/api/files/delete", axum::routing::delete(delete))
}

/// Resolve a `path` relative to the active project (if any) or the user's
/// home directory. Absolute paths are accepted; `..` traversal is prevented.
/// A `thread_id` takes precedence over `project_id`: the root becomes the
/// thread's working directory, i.e. its worktree when the thread runs in
/// worktree mode and the project root otherwise.
///
/// Owners may reach any absolute path. Non-owners are confined to their own
/// projects and the shared managed roots (see [`scope`]), and can never
/// touch credential locations or the server's database file.
async fn resolve(
    state: &AppState,
    user: &crate::db::UserRow,
    rel: Option<&str>,
    project_id: Option<i64>,
    thread_id: Option<&str>,
) -> Result<(PathBuf, PathBuf), Response> {
    let home_dir = &state.config.home_dir;

    let project_root = if let Some(tid) = thread_id.filter(|s| !s.trim().is_empty()) {
        match state.db.get_thread(tid, user.id).await {
            Ok(Some(t)) => {
                // A thread whose project row was deleted has no meaningful
                // root; reject instead of falling back to the home dir.
                if let Some(pid) = t.project_id {
                    if !matches!(state.db.get_project(pid, user.id).await, Ok(Some(_))) {
                        return Err((
                            StatusCode::BAD_REQUEST,
                            Json(crate::api::ApiError::new("invalid thread_id")),
                        )
                            .into_response());
                    }
                }
                Some(
                    crate::api::threads::plan::project_working_dir_for_thread(state, &t)
                        .await
                        .map_err(crate::api::map_err_internal)
                        .map_err(IntoResponse::into_response)?,
                )
            }
            _ => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid thread_id")),
                )
                    .into_response())
            }
        }
    } else if let Some(pid) = project_id {
        match state.db.get_project(pid, user.id).await {
            Ok(Some(p)) => Some(PathBuf::from(p.path)),
            _ => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid project_id")),
                )
                    .into_response())
            }
        }
    } else {
        None
    };

    let root_canon = match project_root.as_ref() {
        Some(p) => match p.canonicalize() {
            Ok(c) => c,
            Err(_) => p.clone(),
        },
        // Non-owners have no home-directory scope; their default browse root
        // is the managed project root.
        None if !user.is_owner => {
            match crate::api::settings::project_root(state, user.id).await {
                Ok(root) => root,
                Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
            }
        }
        None => match home_dir.canonicalize() {
            Ok(c) => c,
            Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
        },
    };

    // The authorized root set only exists for non-owners; owners keep the
    // historical unrestricted behavior.
    let (allowed, db_files) = if user.is_owner {
        (Vec::new(), Vec::new())
    } else {
        let mut roots = crate::api::scope::non_owner_roots(state, user).await;
        roots.push(root_canon.clone());
        (roots, crate::api::scope::db_file_paths(state))
    };

    let rel = rel.unwrap_or("");
    let target = if rel.is_empty() {
        root_canon.clone()
    } else if Path::new(rel).is_absolute() {
        PathBuf::from(rel)
    } else {
        root_canon.join(rel)
    };

    let resolved = if rel.is_empty() {
        paths::resolve_within(
            &target,
            Some(&root_canon),
            std::slice::from_ref(&root_canon),
        )
    } else if Path::new(rel).is_absolute() {
        if user.is_owner {
            paths::resolve(Path::new(rel), None, None)
        } else {
            paths::resolve(Path::new(rel), None, Some(&allowed))
        }
    } else {
        paths::resolve_within(
            &target,
            Some(&root_canon),
            std::slice::from_ref(&root_canon),
        )
    };

    let invalid = || {
        (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid path")),
        )
            .into_response()
    };

    match resolved {
        Some(p) if paths::is_hidden_within(&root_canon, &p) => Err(invalid()),
        Some(p) if !user.is_owner && scope::outside_scope(&p, &allowed, &db_files) => {
            Err(invalid())
        }
        Some(p) => Ok((p, root_canon)),
        None => Err(invalid()),
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ListQuery {
    path: Option<String>,
    project_id: Option<i64>,
    thread_id: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ReadQuery {
    path: Option<String>,
    project_id: Option<i64>,
    thread_id: Option<String>,
    #[serde(default)]
    diff: bool,
}

#[derive(Debug, Serialize)]
struct DirEntry {
    name: String,
    is_dir: bool,
    size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    git_status: Option<String>,
}

async fn list_dir(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _root) = match resolve(
        &state,
        &user,
        q.path.as_deref(),
        q.project_id,
        q.thread_id.as_deref(),
    )
    .await
    {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut entries = match tokio::fs::read_dir(&target).await {
        Ok(rd) => rd,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let mut entries_sorted = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();
        // Skip hidden attachment and git metadata entries. Non-owners also
        // never see credential locations in listings.
        if paths::is_hidden_name(&name)
            || (!user.is_owner && paths::is_sensitive_name(&name))
        {
            continue;
        }
        let is_dir = entry
            .file_type()
            .await
            .map(|t| t.is_dir())
            .unwrap_or(false);
        entries_sorted.push((is_dir, name, entry));
    }
    entries_sorted.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));

    let git_statuses = if state.git.is_enabled() {
        state.git.file_statuses(&target).await.unwrap_or_default()
    } else {
        HashMap::new()
    };

    let limit = q
        .limit
        .filter(|&l| l > 0)
        .map(|l| (l as usize).min(crate::api::pagination::Pagination::MAX_LIMIT as usize));
    let offset = q.offset.unwrap_or(0).max(0) as usize;
    let page: Vec<_> = entries_sorted
        .into_iter()
        .skip(offset)
        .take(limit.unwrap_or(usize::MAX))
        .collect();

    // Stat only the entries that survive pagination; on huge directories the
    // metadata call is the expensive part.
    let mut out = Vec::with_capacity(page.len());
    for (is_dir, name, entry) in page {
        let size = entry.metadata().await.map(|m| m.len()).unwrap_or(0);
        out.push(DirEntry {
            git_status: git_statuses.get(&name).cloned(),
            name,
            is_dir,
            size,
        });
    }

    Json(out).into_response()
}

fn hex_sha256(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn mtime_rfc3339(meta: &std::fs::Metadata) -> Option<String> {
    let modified = meta.modified().ok()?;
    let duration = modified.duration_since(std::time::UNIX_EPOCH).ok()?;
    DateTime::from_timestamp(duration.as_secs() as i64, duration.subsec_nanos())
        .map(|dt| dt.to_rfc3339())
}

async fn read_file(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ReadQuery>,
) -> Response {
    let (target, _root) = match resolve(
        &state,
        &user,
        q.path.as_deref(),
        q.project_id,
        q.thread_id.as_deref(),
    )
    .await
    {
        Ok(v) => v,
        Err(r) => return r,
    };
    let meta = match tokio::fs::metadata(&target).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    // Only regular files are editable/viewable inline; directories are listed,
    // not read, but guard against odd paths.
    if meta.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("path is a directory")),
        )
            .into_response();
    }
    if meta.len() > 4 * 1024 * 1024 {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(crate::api::ApiError::new(
                "file too large for inline read (max 4 MiB)",
            )),
        )
            .into_response();
    }
    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let sha256 = hex_sha256(&bytes);
    let last_modified = mtime_rfc3339(&meta);
    let mime = mime_guess::from_path(&target)
        .first_or_octet_stream()
        .to_string();
    let text = std::str::from_utf8(&bytes).ok().map(|s| s.to_string());
    let diff = if q.diff && state.git.is_enabled() {
        if let Some(ref text) = text {
            match state.git.text_diff(&target, text).await {
                Ok(d) => d,
                Err(e) => {
                    tracing::warn!(error = %e, "file diff failed");
                    None
                }
            }
        } else {
            None
        }
    } else {
        None
    };
    // When a diff is present, the content text is duplicated inside the diff,
    // so omit the top-level text to keep the response compact.
    let response_text = if diff.is_some() { None } else { text };
    Json(serde_json::json!({
        "path": target.to_string_lossy(),
        "mime": mime,
        "size": bytes.len(),
        "base64": b64,
        "sha256": sha256,
        "last_modified": last_modified,
        "text": response_text,
        "diff": diff,
    }))
    .into_response()
}

#[derive(Debug, Deserialize)]
struct WriteReq {
    path: String,
    #[serde(default)]
    project_id: Option<i64>,
    #[serde(default)]
    thread_id: Option<String>,
    content: String,
    #[serde(default)]
    expected_sha256: Option<String>,
}

#[derive(Debug, Serialize)]
struct WriteConflict {
    error: String,
    current: serde_json::Value,
}

async fn write_file(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<WriteReq>,
) -> Response {
    let (target, _root) = match resolve(
        &state,
        &user,
        Some(&req.path),
        req.project_id,
        req.thread_id.as_deref(),
    )
    .await
    {
        Ok(v) => v,
        Err(r) => return r,
    };

    let file_lock = file_write_lock(&target);
    let _lock = file_lock.lock().await;

    let content_bytes = req.content.as_bytes();
    let exists = tokio::fs::try_exists(&target).await.unwrap_or(false);

    // If the client expected an existing file (non-empty sha256) and it is gone,
    // treat it as a conflict so the user can reload rather than silently recreate.
    if let Some(expected) = req.expected_sha256.as_deref() {
        if !expected.is_empty() && !exists {
            return (
                StatusCode::CONFLICT,
                Json(WriteConflict {
                    error: "file was deleted".into(),
                    current: serde_json::Value::Null,
                }),
            )
                .into_response();
        }
    }

    if exists {
        if tokio::fs::metadata(&target)
            .await
            .map(|m| m.is_dir())
            .unwrap_or(false)
        {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("path is a directory")),
            )
                .into_response();
        }

        // Verify the expected sha256 before overwriting. Returning the current
        // content on conflict lets the editor prompt the user to reload.
        if let Some(expected) = req.expected_sha256.as_deref() {
            if !expected.is_empty() {
                let current = match tokio::fs::read(&target).await {
                    Ok(b) => b,
                    Err(e) => return crate::api::map_err_internal(e).into_response(),
                };
                let meta = tokio::fs::metadata(&target).await.ok();
                let current_hash = hex_sha256(&current);
                if current_hash != expected {
                    let current_text = String::from_utf8_lossy(&current).to_string();
                    let last_modified = meta.as_ref().and_then(mtime_rfc3339);
                    let conflict = serde_json::json!({
                        "path": target.to_string_lossy(),
                        "mime": mime_guess::from_path(&target).first_or_octet_stream().to_string(),
                        "size": current.len(),
                        "base64": base64::engine::general_purpose::STANDARD.encode(&current),
                        "sha256": current_hash,
                        "last_modified": last_modified,
                        "text": current_text,
                        "diff": null,
                    });
                    return (
                        StatusCode::CONFLICT,
                        Json(WriteConflict {
                            error: "file changed on disk".into(),
                            current: conflict,
                        }),
                    )
                        .into_response();
                }
            }
        }
    }

    // Ensure the parent directory exists before writing.
    if let Some(parent) = target.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            return crate::api::map_err_internal(e).into_response();
        }
    }

    if let Err(e) = tokio::fs::write(&target, content_bytes).await {
        return crate::api::map_err_internal(e).into_response();
    }

    // Re-read so the response matches the on-disk state (mtime, size, hash).
    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let meta = match tokio::fs::metadata(&target).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let sha256 = hex_sha256(&bytes);
    let last_modified = mtime_rfc3339(&meta);
    let mime = mime_guess::from_path(&target)
        .first_or_octet_stream()
        .to_string();
    let text = std::str::from_utf8(&bytes).ok().map(|s| s.to_string());

    Json(serde_json::json!({
        "path": target.to_string_lossy(),
        "mime": mime,
        "size": bytes.len(),
        "base64": b64,
        "sha256": sha256,
        "last_modified": last_modified,
        "text": text,
        "diff": null,
    }))
    .into_response()
}

async fn upload(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    mut multipart: Multipart,
) -> Response {
    // Fields: "path" (optional relative dir), "project_id"/"thread_id"
    // (optional scope), file fields.
    let mut dest_dir_rel: Option<String> = None;
    let mut project_id: Option<i64> = None;
    let mut thread_id: Option<String> = None;
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();

    loop {
        let field = match multipart.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return multipart_err(e),
        };
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return multipart_err(e),
        };
        if name == "path" {
            dest_dir_rel = Some(String::from_utf8_lossy(&bytes).to_string());
            continue;
        }
        if name == "project_id" {
            project_id = String::from_utf8_lossy(&bytes).parse().ok();
            continue;
        }
        if name == "thread_id" {
            let raw = String::from_utf8_lossy(&bytes).to_string();
            thread_id = Some(raw);
            continue;
        }
        if filename.is_empty() || filename.len() > 255 {
            continue;
        }
        if bytes.len() > state.config.max_body_bytes {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(crate::api::ApiError::new("file too large")),
            )
                .into_response();
        }
        files.push((filename, bytes.to_vec()));
    }

    let (root_base, _root) =
        match resolve(&state, &user, None, project_id, thread_id.as_deref()).await {
            Ok(v) => v,
            Err(r) => return r,
        };

    // Same scope rules as `resolve`: absolute destination dirs for
    // non-owners must stay inside the authorized root set.
    let (allowed, db_files) = if user.is_owner {
        (Vec::new(), Vec::new())
    } else {
        let mut roots = crate::api::scope::non_owner_roots(&state, &user).await;
        roots.push(root_base.clone());
        (roots, crate::api::scope::db_file_paths(&state))
    };

    let mut uploaded: Vec<String> = Vec::new();
    for (filename, bytes) in files {
        let safe: String = filename
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        let rel = dest_dir_rel.as_deref().unwrap_or("");
        let target = if rel.is_empty() {
            root_base.join(&safe)
        } else if std::path::Path::new(rel).is_absolute() {
            PathBuf::from(rel).join(&safe)
        } else {
            root_base.join(rel).join(&safe)
        };
        let resolved = if std::path::Path::new(rel).is_absolute() {
            if user.is_owner {
                paths::resolve(&target, None, None)
            } else {
                paths::resolve(&target, None, Some(&allowed))
            }
        } else {
            paths::resolve_within(&target, Some(&root_base), std::slice::from_ref(&root_base))
        };
        let resolved = match resolved {
            Some(p)
                if !paths::is_hidden_within(&root_base, &p)
                    && (user.is_owner
                        || !scope::outside_scope(&p, &allowed, &db_files)) =>
            {
                p
            }
            _ => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid upload path")),
                )
                    .into_response()
            }
        };
        if let Some(parent) = resolved.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        if let Err(e) = tokio::fs::write(&resolved, &bytes).await {
            return crate::api::map_err_internal(e).into_response();
        }
        uploaded.push(resolved.to_string_lossy().to_string());
    }
    Json(serde_json::json!({"ok": true, "uploaded": uploaded})).into_response()
}

#[derive(Debug, Deserialize)]
struct MkdirReq {
    path: String,
    #[serde(default)]
    project_id: Option<i64>,
    #[serde(default)]
    thread_id: Option<String>,
}

async fn mkdir(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<MkdirReq>,
) -> Response {
    let (target, _root) = match resolve(
        &state,
        &user,
        Some(&req.path),
        req.project_id,
        req.thread_id.as_deref(),
    )
    .await
    {
        Ok(v) => v,
        Err(r) => return r,
    };
    if let Err(e) = tokio::fs::create_dir_all(&target).await {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    let rel = q.path.as_deref().unwrap_or("").trim_end_matches('/');
    let (_resolved, root) = match resolve(
        &state,
        &user,
        q.path.as_deref(),
        q.project_id,
        q.thread_id.as_deref(),
    )
    .await
    {
        Ok(v) => v,
        Err(r) => return r,
    };
    let invalid = || {
        (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid path")),
        )
            .into_response()
    };
    // `resolve` returns the canonicalized path, which turns a symlink into
    // its target. Delete must act on the link itself, so rebuild the lexical
    // path and lstat that instead of removing whatever it points at.
    let target = if rel.is_empty() {
        return invalid();
    } else if Path::new(rel).is_absolute() {
        PathBuf::from(rel)
    } else {
        root.join(rel)
    };
    // The final raw segment must be a real name: `dir/.` resolves to the
    // directory itself and `dir/..` to its parent, so removing either would
    // hit a different object than the entry the user picked. Relative
    // targets must also stay under the root so `..` cannot delete the root
    // itself.
    let last = rel.rsplit('/').next().unwrap_or("");
    if last == "." || last == ".."
        || (!Path::new(rel).is_absolute()
            && !paths::normalize_lexical(&target).starts_with(&root))
    {
        return invalid();
    }
    let (Some(parent), Some(name)) = (target.parent(), target.file_name()) else {
        return invalid();
    };
    // `resolve` scope-checked the path when it was read; a mid-path
    // component swapped for a symlink since then would redirect the delete
    // outside the authorized root, so pin the parent first.
    let canon_parent = match tokio::fs::canonicalize(parent).await {
        Ok(p) => p,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    if !user.is_owner {
        let mut allowed = scope::non_owner_roots(&state, &user).await;
        allowed.push(root.clone());
        if scope::outside_scope(&canon_parent, &allowed, &scope::db_file_paths(&state)) {
            return invalid();
        }
    }
    let (_pinned, op_dir) = match pin_delete_dir(&canon_parent) {
        Ok(v) => v,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let op_target = op_dir.join(name);
    let meta = match tokio::fs::symlink_metadata(&op_target).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let result = if meta.is_dir() {
        tokio::fs::remove_dir_all(&op_target).await
    } else {
        tokio::fs::remove_file(&op_target).await
    };
    if let Err(e) = result {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}
