//! File manager API routes.
//!
//! All operations are constrained to a workspace's directory (which is itself
//! within a configured workspace root). Path traversal is prevented by
//! canonicalizing and checking containment.

use std::path::PathBuf;

use axum::extract::{Multipart, Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::UserRow;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/workspaces/:id/files", get(list_dir).post(upload))
        .route("/api/workspaces/:id/files/content", get(read_file))
        .route("/api/workspaces/:id/files/dir", post(mkdir))
        .route("/api/workspaces/:id/files/move", post(mv))
        .route("/api/workspaces/:id/files/delete", axum::routing::delete(delete))
}

/// Resolve a relative `path` query param within the workspace, returning
/// (canonical_path, workspace_path) or a 400 response.
async fn resolve(
    state: &AppState,
    user: &UserRow,
    workspace_id: i64,
    rel: Option<&str>,
) -> Result<(PathBuf, PathBuf), Response> {
    let ws = match state.db.get_workspace(workspace_id, user.id).await {
        Ok(Some(w)) => w,
        Ok(None) => {
            return Err((StatusCode::NOT_FOUND, Json(crate::api::ApiError::new("workspace not found"))).into_response());
        }
        Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
    };
    let ws_path = PathBuf::from(&ws.path);
    let ws_canon = match ws_path.canonicalize() {
        Ok(c) => c,
        Err(e) => return Err(crate::api::map_err_internal(e).into_response()),
    };
    let rel = rel.unwrap_or("");
    let target = if rel.is_empty() {
        ws_canon.clone()
    } else {
        ws_canon.join(rel)
    };
    // Use resolve_within with the workspace canon as base and roots = [ws_canon].
    let roots = vec![ws_canon.clone()];
    match paths::resolve_within(&target, Some(&ws_canon), &roots) {
        Some(p) => Ok((p, ws_canon)),
        None => Err((StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("path escapes workspace"))).into_response()),
    }
}

#[derive(Debug, Deserialize)]
struct ListQuery {
    #[serde(default)]
    path: Option<String>,
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
    Path(wid): Path<i64>,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _ws) = match resolve(&state, &user, wid, q.path.as_deref()).await {
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
    Path(wid): Path<i64>,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _ws) = match resolve(&state, &user, wid, q.path.as_deref()).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let bytes = match tokio::fs::read(&target).await {
        Ok(b) => b,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };
    // Limit to 4 MiB for inline read.
    if bytes.len() > 4 * 1024 * 1024 {
        return (StatusCode::PAYLOAD_TOO_LARGE, Json(crate::api::ApiError::new("file too large for inline read (max 4 MiB)"))).into_response();
    }
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let mime = mime_guess::from_path(&target).first_or_octet_stream().to_string();
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
    Path(wid): Path<i64>,
    mut multipart: Multipart,
) -> Response {
    // Fields: "path" (optional relative dir to upload into), file fields.
    let (ws_base, _ws) = match resolve(&state, &user, wid, None).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let mut dest_dir_rel: Option<String> = None;
    let mut uploaded: Vec<String> = Vec::new();
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
        if filename.is_empty() || filename.len() > 255 {
            continue;
        }
        if bytes.len() > 16 * 1024 * 1024 {
            return (StatusCode::PAYLOAD_TOO_LARGE, Json(crate::api::ApiError::new("file too large (max 16 MiB)"))).into_response();
        }
        // Sanitize filename.
        let safe: String = filename
            .chars()
            .map(|c| if c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '_' })
            .collect();
        let rel = dest_dir_rel.as_deref().unwrap_or("");
        let target = if rel.is_empty() {
            ws_base.join(&safe)
        } else {
            ws_base.join(rel).join(&safe)
        };
        let roots = vec![ws_base.clone()];
        let resolved = match paths::resolve_within(&target, Some(&ws_base), &roots) {
            Some(p) => p,
            None => return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("path escapes workspace"))).into_response(),
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
}

async fn mkdir(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(wid): Path<i64>,
    Json(req): Json<MkdirReq>,
) -> Response {
    let (target, _ws) = match resolve(&state, &user, wid, Some(&req.path)).await {
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
    Path(wid): Path<i64>,
    Json(req): Json<MoveReq>,
) -> Response {
    let (from, ws) = match resolve(&state, &user, wid, Some(&req.from)).await {
        Ok(v) => v,
        Err(r) => return r,
    };
    let to_target = ws.join(&req.to);
    let roots = vec![ws.clone()];
    let to = match paths::resolve_within(&to_target, Some(&ws), &roots) {
        Some(p) => p,
        None => return (StatusCode::BAD_REQUEST, Json(crate::api::ApiError::new("destination escapes workspace"))).into_response(),
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
    Path(wid): Path<i64>,
    Query(q): Query<ListQuery>,
) -> Response {
    let (target, _ws) = match resolve(&state, &user, wid, q.path.as_deref()).await {
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
