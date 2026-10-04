//! Satellite file endpoints: the hub's file API shape, keyed by explicit
//! `root` paths instead of project/thread rows.
//!
//! `root` is an absolute directory the caller resolved server-side (a
//! project path or a thread's working dir); when absent the satellite's own
//! home directory is the root. `path` entries may be relative to the root
//! or absolute. The same hidden-path rules as the hub apply: `.git` and
//! `.devinorium-attachments` are never listed or touched.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::extract::{Multipart, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::DateTime;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::node::{StatOut, StatRequest, StatResponse};
use crate::satellite::{bad_request, internal, SatelliteState};
use crate::security::paths;

pub fn router() -> Router<Arc<SatelliteState>> {
    Router::new()
        .route("/api/node/files", get(list_dir).post(upload))
        .route("/api/node/files/content", get(read_file).put(write_file))
        .route("/api/node/files/dir", post(mkdir))
        .route("/api/node/files/delete", axum::routing::delete(delete))
        .route("/api/node/files/stat", post(stat))
}

fn invalid() -> Response {
    bad_request("invalid path")
}

/// Resolve the browse root: the caller-supplied absolute path, or the
/// satellite's home directory. A root that does not exist still resolves
/// lexically so `mkdir`-style calls can create it.
async fn resolve_root(state: &SatelliteState, root: Option<&str>) -> Result<PathBuf, Response> {
    let base = match root.map(str::trim).filter(|s| !s.is_empty()) {
        Some(r) => {
            let p = PathBuf::from(r);
            if !p.is_absolute() {
                return Err(bad_request("root must be an absolute path"));
            }
            p
        }
        None => state.home_dir.clone(),
    };
    match tokio::fs::canonicalize(&base).await {
        Ok(c) => Ok(c),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(paths::normalize_lexical(&base)),
        Err(e) => Err(internal(e)),
    }
}

/// Resolve `rel` against `root` with the hub's traversal and hidden-path
/// rules. Returns the canonical target.
async fn resolve(
    state: &SatelliteState,
    root: Option<&str>,
    rel: Option<&str>,
) -> Result<(PathBuf, PathBuf), Response> {
    let root_canon = resolve_root(state, root).await?;
    let rel = rel.unwrap_or("");
    let target = if rel.is_empty() {
        root_canon.clone()
    } else {
        let p = Path::new(rel);
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            root_canon.join(p)
        }
    };
    let resolved = if rel.is_empty() || !Path::new(rel).is_absolute() {
        paths::resolve_within(
            &target,
            Some(&root_canon),
            std::slice::from_ref(&root_canon),
        )
    } else {
        paths::resolve(&target, None, None)
    };
    match resolved {
        Some(p) if paths::is_hidden_within(&root_canon, &p) => Err(invalid()),
        Some(p) => Ok((p, root_canon)),
        None => Err(invalid()),
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ListQuery {
    root: Option<String>,
    path: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
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
    State(state): State<Arc<SatelliteState>>,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _root) = match resolve(&state, q.root.as_deref(), q.path.as_deref()).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut entries = match tokio::fs::read_dir(&target).await {
        Ok(rd) => rd,
        Err(e) => return internal(e).into_response(),
    };
    let mut entries_sorted = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();
        if paths::is_hidden_name(&name) {
            continue;
        }
        let is_dir = entry.file_type().await.map(|t| t.is_dir()).unwrap_or(false);
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

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ReadQuery {
    root: Option<String>,
    path: Option<String>,
    diff: bool,
}

async fn read_file(
    State(state): State<Arc<SatelliteState>>,
    Query(q): Query<ReadQuery>,
) -> Response {
    let (target, _root) = match resolve(&state, q.root.as_deref(), q.path.as_deref()).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let meta = match tokio::fs::metadata(&target).await {
        Ok(m) => m,
        Err(e) => return internal(e).into_response(),
    };
    if meta.is_dir() {
        return bad_request("path is a directory");
    }
    if meta.len() > 4 * 1024 * 1024 {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(crate::node::NodeError::new(
                "too_large",
                "file too large for inline read (max 4 MiB)",
            )),
        )
            .into_response();
    }
    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return internal(e).into_response(),
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
    #[serde(default)]
    root: Option<String>,
    path: String,
    content: String,
    #[serde(default)]
    expected_sha256: Option<String>,
}

async fn write_file(
    State(state): State<Arc<SatelliteState>>,
    Json(req): Json<WriteReq>,
) -> Response {
    let (target, _root) = match resolve(&state, req.root.as_deref(), Some(&req.path)).await {
        Ok(v) => v,
        Err(r) => return r,
    };

    let content_bytes = req.content.as_bytes();
    let exists = tokio::fs::try_exists(&target).await.unwrap_or(false);

    if let Some(expected) = req.expected_sha256.as_deref() {
        if !expected.is_empty() && !exists {
            return (
                StatusCode::CONFLICT,
                Json(serde_json::json!({"error": "file was deleted", "current": null})),
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
            return bad_request("path is a directory");
        }
        if let Some(expected) = req.expected_sha256.as_deref() {
            if !expected.is_empty() {
                let current = match tokio::fs::read(&target).await {
                    Ok(b) => b,
                    Err(e) => return internal(e).into_response(),
                };
                let current_hash = hex_sha256(&current);
                if current_hash != expected {
                    use base64::Engine;
                    let meta = tokio::fs::metadata(&target).await.ok();
                    let conflict = serde_json::json!({
                        "path": target.to_string_lossy(),
                        "mime": mime_guess::from_path(&target).first_or_octet_stream().to_string(),
                        "size": current.len(),
                        "base64": base64::engine::general_purpose::STANDARD.encode(&current),
                        "sha256": current_hash,
                        "last_modified": meta.as_ref().and_then(mtime_rfc3339),
                        "text": String::from_utf8_lossy(&current).to_string(),
                        "diff": null,
                    });
                    return (
                        StatusCode::CONFLICT,
                        Json(serde_json::json!({
                            "error": "file changed on disk",
                            "current": conflict,
                        })),
                    )
                        .into_response();
                }
            }
        }
    }

    if let Some(parent) = target.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            return internal(e).into_response();
        }
    }
    if let Err(e) = tokio::fs::write(&target, content_bytes).await {
        return internal(e).into_response();
    }

    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return internal(e).into_response(),
    };
    let meta = match tokio::fs::metadata(&target).await {
        Ok(m) => m,
        Err(e) => return internal(e).into_response(),
    };
    use base64::Engine;
    Json(serde_json::json!({
        "path": target.to_string_lossy(),
        "mime": mime_guess::from_path(&target).first_or_octet_stream().to_string(),
        "size": bytes.len(),
        "base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
        "sha256": hex_sha256(&bytes),
        "last_modified": mtime_rfc3339(&meta),
        "text": std::str::from_utf8(&bytes).ok().map(|s| s.to_string()),
        "diff": null,
    }))
    .into_response()
}

#[derive(Debug, Deserialize)]
struct MkdirReq {
    #[serde(default)]
    root: Option<String>,
    path: String,
}

async fn mkdir(State(state): State<Arc<SatelliteState>>, Json(req): Json<MkdirReq>) -> Response {
    let (target, _root) = match resolve(&state, req.root.as_deref(), Some(&req.path)).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    if let Err(e) = tokio::fs::create_dir_all(&target).await {
        return internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct DeleteQuery {
    root: Option<String>,
    path: Option<String>,
}

async fn delete(
    State(state): State<Arc<SatelliteState>>,
    Query(q): Query<DeleteQuery>,
) -> Response {
    let rel = q.path.as_deref().unwrap_or("").trim_end_matches('/');
    if rel.is_empty() {
        return invalid();
    }
    let (_resolved, root) = match resolve(&state, q.root.as_deref(), Some(rel)).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let target = if Path::new(rel).is_absolute() {
        PathBuf::from(rel)
    } else {
        root.join(rel)
    };
    let last = rel.rsplit('/').next().unwrap_or("");
    if last == "."
        || last == ".."
        || (!Path::new(rel).is_absolute() && !paths::normalize_lexical(&target).starts_with(&root))
    {
        return invalid();
    }
    let (Some(parent), Some(name)) = (target.parent(), target.file_name()) else {
        return invalid();
    };
    let canon_parent = match tokio::fs::canonicalize(parent).await {
        Ok(p) => p,
        Err(e) => return internal(e).into_response(),
    };
    let op_target = canon_parent.join(name);
    let meta = match tokio::fs::symlink_metadata(&op_target).await {
        Ok(m) => m,
        Err(e) => return internal(e).into_response(),
    };
    let result = if meta.is_dir() {
        tokio::fs::remove_dir_all(&op_target).await
    } else {
        tokio::fs::remove_file(&op_target).await
    };
    if let Err(e) = result {
        return internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn upload(State(state): State<Arc<SatelliteState>>, mut multipart: Multipart) -> Response {
    let mut root: Option<String> = None;
    let mut dest_dir_rel: Option<String> = None;
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();

    loop {
        let field = match multipart.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return crate::api::files::multipart_err(e),
        };
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return crate::api::files::multipart_err(e),
        };
        if name == "root" {
            root = Some(String::from_utf8_lossy(&bytes).to_string());
            continue;
        }
        if name == "path" {
            dest_dir_rel = Some(String::from_utf8_lossy(&bytes).to_string());
            continue;
        }
        if filename.is_empty() || filename.len() > 255 {
            continue;
        }
        if bytes.len() > state.max_body_bytes {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(crate::node::NodeError::new("too_large", "file too large")),
            )
                .into_response();
        }
        files.push((filename, bytes.to_vec()));
    }

    let root_canon = match resolve_root(&state, root.as_deref()).await {
        Ok(r) => r,
        Err(r) => return r,
    };
    let dest_dir = match dest_dir_rel.as_deref() {
        Some(rel) => match resolve(&state, Some(&root_canon.to_string_lossy()), Some(rel)).await {
            Ok((p, _)) => p,
            Err(r) => return r,
        },
        None => root_canon.clone(),
    };
    if let Err(e) = tokio::fs::create_dir_all(&dest_dir).await {
        return internal(e).into_response();
    }

    let mut uploaded = Vec::new();
    for (filename, bytes) in files {
        let Some(name) = Path::new(&filename).file_name() else {
            continue;
        };
        let target = dest_dir.join(name);
        if paths::is_hidden_within(&root_canon, &target) {
            continue;
        }
        match tokio::fs::write(&target, &bytes).await {
            Ok(()) => uploaded.push(target.to_string_lossy().to_string()),
            Err(e) => return internal(e).into_response(),
        }
    }
    Json(serde_json::json!({"ok": true, "uploaded": uploaded})).into_response()
}

/// Stat a batch of paths for the hub's context-reference and worktree
/// checks. Missing entries report `exists: false` instead of failing.
async fn stat(State(state): State<Arc<SatelliteState>>, Json(req): Json<StatRequest>) -> Response {
    if req.paths.len() > 256 {
        return bad_request("too many paths");
    }
    let mut results = HashMap::with_capacity(req.paths.len());
    for raw in &req.paths {
        let out = stat_one(&state, req.root.as_deref(), raw).await;
        results.insert(raw.clone(), out);
    }
    Json(StatResponse { results }).into_response()
}

async fn stat_one(state: &SatelliteState, root: Option<&str>, raw: &str) -> StatOut {
    let p = Path::new(raw);
    let target = if p.is_absolute() {
        p.to_path_buf()
    } else {
        // A broken root must not silently stat relative to the process
        // working directory — report the path as missing instead.
        match resolve_root(state, root).await {
            Ok(r) => r.join(p),
            Err(_) => {
                return StatOut {
                    exists: false,
                    is_dir: false,
                    is_symlink: false,
                    canonical: None,
                    size: 0,
                    modified: None,
                }
            }
        }
    };
    let meta = match tokio::fs::symlink_metadata(&target).await {
        Ok(m) => m,
        Err(_) => {
            return StatOut {
                exists: false,
                is_dir: false,
                is_symlink: false,
                canonical: None,
                size: 0,
                modified: None,
            }
        }
    };
    let canonical = tokio::fs::canonicalize(&target)
        .await
        .ok()
        .map(|c| c.to_string_lossy().to_string());
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);
    StatOut {
        exists: true,
        is_dir: meta.is_dir(),
        is_symlink: meta.file_type().is_symlink(),
        canonical,
        size: meta.len(),
        modified,
    }
}
