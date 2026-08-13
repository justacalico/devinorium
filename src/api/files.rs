//! File manager API routes.
//!
//! Paths are resolved relative to the active project (if any) or the user's
//! home directory. Absolute paths are accepted, and path traversal via `..`
//! is prevented by canonicalization.

use std::path::{Path, PathBuf};

use axum::extract::{Multipart, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/files", get(list_dir).post(upload))
        .route("/api/files/content", get(read_file))
        .route("/api/files/dir", post(mkdir))
        .route("/api/files/move", post(mv))
        .route("/api/files/delete", axum::routing::delete(delete))
}

/// Resolve a `path` relative to the active project (if any) or the user's
/// home directory. Absolute paths are accepted; `..` traversal is prevented.
async fn resolve(
    state: &AppState,
    user_id: i64,
    rel: Option<&str>,
    project_id: Option<i64>,
) -> Result<(PathBuf, PathBuf), Response> {
    let home_dir = &state.config.home_dir;

    let project_root = if let Some(pid) = project_id {
        match state.db.get_project(pid, user_id).await {
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
        None => match home_dir.canonicalize() {
            Ok(c) => c,
            Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
        },
    };

    let rel = rel.unwrap_or("");
    if rel.is_empty() {
        match paths::resolve_within(&root_canon, Some(&root_canon), &[root_canon.clone()]) {
            Some(p) => Ok((p, root_canon)),
            None => Err((
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid path")),
            )
                .into_response()),
        }
    } else if std::path::Path::new(rel).is_absolute() {
        match paths::resolve(Path::new(rel), None, None) {
            Some(p) => Ok((p, root_canon)),
            None => Err((
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid path")),
            )
                .into_response()),
        }
    } else {
        let target = root_canon.join(rel);
        match paths::resolve_within(&target, Some(&root_canon), &[root_canon.clone()]) {
            Some(p) => Ok((p, root_canon)),
            None => Err((
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid path")),
            )
                .into_response()),
        }
    }
}

#[derive(Debug, Deserialize)]
struct ListQuery {
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    project_id: Option<i64>,
}

#[derive(Debug, Serialize)]
struct DirEntry {
    name: String,
    is_dir: bool,
    size: u64,
}

async fn list_dir(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _root) = match resolve(&state, user.id, q.path.as_deref(), q.project_id).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut entries = match tokio::fs::read_dir(&target).await {
        Ok(rd) => rd,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let mut out = Vec::new();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name().to_string_lossy().to_string();
        // Skip the hidden attachment dir.
        if name == ".devinorium-attachments" {
            continue;
        }
        let ft = entry.file_type().await.ok();
        let size = entry.metadata().await.map(|m| m.len()).unwrap_or(0);
        out.push(DirEntry {
            name,
            is_dir: ft.map(|t| t.is_dir()).unwrap_or(false),
            size,
        });
    }
    out.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.cmp(&b.name)));
    Json(out).into_response()
}

async fn read_file(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _root) = match resolve(&state, user.id, q.path.as_deref(), q.project_id).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    // Limit to 4 MiB for inline read.
    if bytes.len() > 4 * 1024 * 1024 {
        return (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(crate::api::ApiError::new(
                "file too large for inline read (max 4 MiB)",
            )),
        )
            .into_response();
    }
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let mime = mime_guess::from_path(&target)
        .first_or_octet_stream()
        .to_string();
    Json(serde_json::json!({
        "path": target.to_string_lossy(),
        "mime": mime,
        "size": bytes.len(),
        "base64": b64,
    }))
    .into_response()
}

async fn upload(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    mut multipart: Multipart,
) -> Response {
    // Fields: "path" (optional relative dir), "project_id" (optional int), file fields.
    let mut dest_dir_rel: Option<String> = None;
    let mut project_id: Option<i64> = None;
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("").to_string();
        let bytes = match field.bytes().await {
            Ok(b) => b,
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        };
        if name == "path" {
            dest_dir_rel = Some(String::from_utf8_lossy(&bytes).to_string());
            continue;
        }
        if name == "project_id" {
            project_id = String::from_utf8_lossy(&bytes).parse().ok();
            continue;
        }
        if filename.is_empty() || filename.len() > 255 {
            continue;
        }
        if bytes.len() > 16 * 1024 * 1024 {
            return (
                StatusCode::PAYLOAD_TOO_LARGE,
                Json(crate::api::ApiError::new("file too large (max 16 MiB)")),
            )
                .into_response();
        }
        files.push((filename, bytes.to_vec()));
    }

    let (root_base, _root) = match resolve(&state, user.id, None, project_id).await {
        Ok(v) => v,
        Err(r) => return r,
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
            paths::resolve(&target, None, None)
        } else {
            paths::resolve_within(&target, Some(&root_base), &[root_base.clone()])
        };
        let resolved = match resolved {
            Some(p) => p,
            None => {
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
}

async fn mkdir(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<MkdirReq>,
) -> Response {
    let (target, _root) = match resolve(&state, user.id, Some(&req.path), req.project_id).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    if let Err(e) = tokio::fs::create_dir_all(&target).await {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

#[derive(Debug, Deserialize)]
struct MoveReq {
    from: String,
    to: String,
}

async fn mv(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<MoveReq>,
) -> Response {
    let (from, root) = match resolve(&state, user.id, Some(&req.from), None).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let to_target = if std::path::Path::new(&req.to).is_absolute() {
        PathBuf::from(&req.to)
    } else {
        root.join(&req.to)
    };
    let to = if std::path::Path::new(&req.to).is_absolute() {
        paths::resolve(&to_target, None, None)
    } else {
        paths::resolve_within(&to_target, Some(&root), &[root.clone()])
    };
    let to = match to {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid destination path")),
            )
                .into_response()
        }
    };
    if let Some(parent) = to.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    if let Err(e) = tokio::fs::rename(&from, &to).await {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}

async fn delete(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _root) = match resolve(&state, user.id, q.path.as_deref(), q.project_id).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let meta = match tokio::fs::symlink_metadata(&target).await {
        Ok(m) => m,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    let result = if meta.is_dir() {
        tokio::fs::remove_dir_all(&target).await
    } else {
        tokio::fs::remove_file(&target).await
    };
    if let Err(e) = result {
        return crate::api::map_err_internal(e).into_response();
    }
    Json(serde_json::json!({"ok": true})).into_response()
}
