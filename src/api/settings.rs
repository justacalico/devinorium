//! Instance settings routes.
//!
//! The clone root, worktree root, and project root are owner-only settings
//! stored on the owner user row. Non-owner users can read them so they know
//! where clones, worktrees, and new project folders will land.

use axum::extract::{Multipart, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put, Router};
use axum::Json;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::mcp::{validate_servers, McpServerConfig};
use crate::mcpb;
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/settings/clone-root", get(get_clone_root))
        .route("/api/settings/clone-root", put(set_clone_root))
        .route("/api/settings/worktree-root", get(get_worktree_root))
        .route("/api/settings/worktree-root", put(set_worktree_root))
        .route("/api/settings/project-root", get(get_project_root))
        .route("/api/settings/project-root", put(set_project_root))
        .route("/api/settings/mcp-servers", get(get_mcp_servers))
        .route("/api/settings/mcp-servers", put(set_mcp_servers))
}

/// `.mcpb` bundle routes. Separate from `router()` so `build_app` can give
/// them a larger body limit than the rest of the API: bundles shipping
/// `node_modules` are far bigger than the default `max_body_bytes`.
pub fn mcpb_router() -> Router<AppState> {
    Router::new()
        .route("/api/settings/mcp-servers/mcpb/inspect", post(inspect_mcpb))
        .route("/api/settings/mcp-servers/mcpb/install", post(install_mcpb))
}

/// Serializes MCP server list writes and bundle installs: install extracts
/// files before the merged list commits, so a concurrent `set_mcp_servers`
/// prune could otherwise delete the in-flight bundle or lose the update.
static MCP_SERVERS_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Debug, Serialize)]
struct CloneRootResponse {
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SetCloneRootRequest {
    path: Option<String>,
}

#[derive(Debug, Serialize)]
struct WorktreeRootResponse {
    path: String,
}

#[derive(Debug, Deserialize)]
struct SetWorktreeRootRequest {
    path: Option<String>,
}

#[derive(Debug, Serialize)]
struct ProjectRootResponse {
    path: String,
}

#[derive(Debug, Deserialize)]
struct SetProjectRootRequest {
    path: Option<String>,
}

/// Validate a user-supplied directory path for a path setting: expand `~`,
/// require an absolute path without traversal, resolve symlinks, and create
/// the directory when missing. Returns the canonical path to store.
async fn checked_dir_path(state: &AppState, path: &str) -> Result<String, Response> {
    // Expand `~` to the home directory while still validating the final string.
    let path = paths::normalize_path(path, &state.config.home_dir);
    let p = Path::new(&path);
    if !p.is_absolute() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("path must be absolute")),
        )
            .into_response());
    }

    // Reject `..` and other traversal components.
    for c in p.components() {
        if matches!(c, std::path::Component::ParentDir) {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError::new("path traversal is not allowed")),
            )
                .into_response());
        }
    }

    // Resolve to a canonical absolute path. This rejects non-existent tails
    // that try to escape via `..` and follows symlinks, so the stored path is
    // stable.
    let resolved = match paths::resolve(p, None, None) {
        Some(r) => r,
        None => {
            return Err(
                (StatusCode::BAD_REQUEST, Json(ApiError::new("invalid path"))).into_response(),
            );
        }
    };

    // Create the directory if missing; reject if it exists as a file.
    match tokio::fs::try_exists(&resolved).await {
        Ok(true) => match tokio::fs::metadata(&resolved).await {
            Ok(meta) if !meta.is_dir() => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new("path is not a directory")),
                )
                    .into_response());
            }
            Ok(_) => {}
            Err(e) => {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot access path: {e}"))),
                )
                    .into_response());
            }
        },
        Ok(false) => {
            if let Err(e) = tokio::fs::create_dir_all(&resolved).await {
                return Err((
                    StatusCode::BAD_REQUEST,
                    Json(ApiError::new(format!("cannot create directory: {e}"))),
                )
                    .into_response());
            }
        }
        Err(e) => {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ApiError::new(format!("cannot check path: {e}"))),
            )
                .into_response());
        }
    }

    let final_path = match tokio::fs::canonicalize(&resolved).await {
        Ok(c) => c,
        Err(_) => resolved,
    };
    Ok(final_path.to_string_lossy().to_string())
}

/// The directory managed worktree roots live under for `user_id`: the
/// owner-configured setting resolved to a canonical absolute path, with `~`
/// (the default) expanding to the server home directory.
pub(crate) async fn worktree_root(state: &AppState, user_id: i64) -> anyhow::Result<PathBuf> {
    let configured = state.db.get_worktree_root(user_id).await?;
    let normalized = paths::normalize_path(&configured, &state.config.home_dir);
    paths::resolve(Path::new(&normalized), None, None)
        .ok_or_else(|| anyhow::anyhow!("invalid worktree root"))
}

async fn get_clone_root(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    match state.db.get_clone_root(user.id).await {
        Ok(path) => Json(CloneRootResponse { path }).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn set_clone_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetCloneRootRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    let path = req.path.as_deref().map(|s| s.trim());
    let path = match path {
        None | Some("") => {
            if let Err(e) = state.db.set_clone_root(user.id, None).await {
                return map_err_internal(e).into_response();
            }
            return Json(CloneRootResponse { path: None }).into_response();
        }
        Some(p) => p,
    };

    let path = match checked_dir_path(&state, path).await {
        Ok(p) => p,
        Err(resp) => return resp,
    };

    if let Err(e) = state.db.set_clone_root(user.id, Some(&path)).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "clone_root.set",
            &serde_json::json!({"path": &path}),
            None,
        )
        .await;

    Json(CloneRootResponse {
        path: Some(path.clone()),
    })
    .into_response()
}

async fn get_worktree_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    match state.db.get_worktree_root(user.id).await {
        // The stored `~` default is returned expanded so the settings page
        // shows the real directory.
        Ok(path) => Json(WorktreeRootResponse {
            path: paths::normalize_path(&path, &state.config.home_dir),
        })
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn set_worktree_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetWorktreeRootRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    // An empty value restores the home-directory default. A bare `~` is
    // stored verbatim so the value keeps tracking the server home directory
    // if it ever changes.
    let raw = req.path.as_deref().map(|s| s.trim());
    let stored = match raw {
        None | Some("") | Some("~") | Some("~/") | Some("~\\") => "~".to_string(),
        Some(p) => match checked_dir_path(&state, p).await {
            Ok(p) => p,
            Err(resp) => return resp,
        },
    };

    if let Err(e) = state.db.set_worktree_root(user.id, &stored).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "worktree_root.set",
            &serde_json::json!({"path": &stored}),
            None,
        )
        .await;

    Json(WorktreeRootResponse {
        path: paths::normalize_path(&stored, &state.config.home_dir),
    })
    .into_response()
}

/// The directory new project folders are created under for `user_id`: the
/// owner-configured setting resolved to a canonical absolute path, with `~`
/// (the default) expanding to the server home directory.
pub(crate) async fn project_root(state: &AppState, user_id: i64) -> anyhow::Result<PathBuf> {
    let configured = state.db.get_project_root(user_id).await?;
    let normalized = paths::normalize_path(&configured, &state.config.home_dir);
    paths::resolve(Path::new(&normalized), None, None)
        .ok_or_else(|| anyhow::anyhow!("invalid project root"))
}

async fn get_project_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    match state.db.get_project_root(user.id).await {
        // The stored `~` default is returned expanded so the settings page
        // shows the real directory.
        Ok(path) => Json(ProjectRootResponse {
            path: paths::normalize_path(&path, &state.config.home_dir),
        })
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn set_project_root(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetProjectRootRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }

    // An empty value restores the home-directory default. A bare `~` is
    // stored verbatim so the value keeps tracking the server home directory
    // if it ever changes.
    let raw = req.path.as_deref().map(|s| s.trim());
    let stored = match raw {
        None | Some("") | Some("~") | Some("~/") | Some("~\\") => "~".to_string(),
        Some(p) => match checked_dir_path(&state, p).await {
            Ok(p) => p,
            Err(resp) => return resp,
        },
    };

    if let Err(e) = state.db.set_project_root(user.id, &stored).await {
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "project_root.set",
            &serde_json::json!({"path": &stored}),
            None,
        )
        .await;

    Json(ProjectRootResponse {
        path: paths::normalize_path(&stored, &state.config.home_dir),
    })
    .into_response()
}

#[derive(Debug, Serialize)]
struct McpServersResponse {
    servers: Vec<McpServerConfig>,
}

#[derive(Debug, Deserialize)]
struct SetMcpServersRequest {
    servers: Vec<McpServerConfig>,
}

/// The owner's MCP server list. Owner-only on read too: `env` and `headers`
/// carry credentials.
async fn get_mcp_servers(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    match state.db.get_mcp_servers(user.id).await {
        Ok(servers) => Json(McpServersResponse { servers }).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Replace the owner's MCP server list wholesale; the client sends the full
/// list so adds, edits, deletes, and enable toggles share one write path.
async fn set_mcp_servers(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetMcpServersRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    if let Err(msg) = validate_servers(&req.servers) {
        return (StatusCode::BAD_REQUEST, Json(ApiError::new(msg))).into_response();
    }
    let _guard = MCP_SERVERS_LOCK.lock().await;
    if let Err(e) = state.db.set_mcp_servers(user.id, &req.servers).await {
        return map_err_internal(e).into_response();
    }

    // The list is the single write path for deletes and renames too, so
    // bundle dirs no server still references get cleaned up here.
    let root = mcpb::bundle_root(&state.config);
    let servers = req.servers.clone();
    let _ = tokio::task::spawn_blocking(move || mcpb::prune_bundles(&root, &servers)).await;

    let _ = state
        .db
        .audit(
            Some(user.id),
            "mcp_servers.set",
            &serde_json::json!({"count": req.servers.len()}),
            None,
        )
        .await;

    Json(McpServersResponse {
        servers: req.servers,
    })
    .into_response()
}

/// Pull the `file` field (the `.mcpb` archive) plus the optional `config`
/// JSON field out of a bundle multipart body.
async fn read_mcpb_multipart(
    mut multipart: Multipart,
) -> Result<(Vec<u8>, serde_json::Map<String, serde_json::Value>), Response> {
    let mut file = None;
    let mut config = serde_json::Map::new();
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(crate::api::files::multipart_err)?
    {
        match field.name().unwrap_or("") {
            "file" => {
                let bytes = field
                    .bytes()
                    .await
                    .map_err(crate::api::files::multipart_err)?;
                if bytes.len() > mcpb::MAX_MCPB_BYTES {
                    return Err((
                        StatusCode::PAYLOAD_TOO_LARGE,
                        Json(ApiError::new("bundle too large")),
                    )
                        .into_response());
                }
                file = Some(bytes.to_vec());
            }
            "config" => {
                let text = field
                    .text()
                    .await
                    .map_err(crate::api::files::multipart_err)?;
                match serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&text) {
                    Ok(map) => config = map,
                    Err(_) => {
                        return Err((
                            StatusCode::BAD_REQUEST,
                            Json(ApiError::new("config must be a JSON object")),
                        )
                            .into_response())
                    }
                }
            }
            _ => {}
        }
    }
    let file = file.ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            Json(ApiError::new("no .mcpb file uploaded")),
        )
            .into_response()
    })?;
    Ok((file, config))
}

fn bad_request(msg: String) -> Response {
    (StatusCode::BAD_REQUEST, Json(ApiError::new(msg))).into_response()
}

/// Inspect an uploaded `.mcpb` without installing it: returns the manifest
/// metadata and the `user_config` fields the owner has to fill in.
async fn inspect_mcpb(
    State(_state): State<AppState>,
    CurrentUser(user): CurrentUser,
    multipart: Multipart,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    let (bytes, _) = match read_mcpb_multipart(multipart).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    match tokio::task::spawn_blocking(move || mcpb::inspect_bundle(&bytes)).await {
        Ok(Ok(info)) => Json(info).into_response(),
        Ok(Err(msg)) => bad_request(msg),
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Install an uploaded `.mcpb`: extract it under the bundle root, resolve
/// `${__dirname}` and `${user_config.*}` placeholders into a stdio server
/// entry, and merge it into the owner's server list (replacing a same-name
/// entry, which makes reinstalls the upgrade path).
async fn install_mcpb(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    multipart: Multipart,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    let (bytes, config) = match read_mcpb_multipart(multipart).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let _guard = MCP_SERVERS_LOCK.lock().await;
    let root = mcpb::bundle_root(&state.config);
    let home = state.config.home_dir.clone();
    let install = {
        let root = root.clone();
        match tokio::task::spawn_blocking(move || {
            mcpb::install_bundle(&bytes, &root, &home, &config)
        })
        .await
        {
            Ok(Ok(i)) => i,
            Ok(Err(msg)) => return bad_request(msg),
            Err(e) => return map_err_internal(e).into_response(),
        }
    };

    let mut servers = match state.db.get_mcp_servers(user.id).await {
        Ok(s) => s,
        Err(e) => return map_err_internal(e).into_response(),
    };
    // Reinstalling keeps the previous entry's enabled flag.
    let mut server = install.server;
    if let Some(existing) = servers.iter().find(|s| s.name == server.name) {
        server.enabled = existing.enabled;
    }
    let installed_name = server.name.clone();
    servers.retain(|s| s.name != server.name);
    let mut merged = servers.clone();
    merged.push(server);
    if let Err(msg) = validate_servers(&merged) {
        // Roll the files back so a rejected list leaves nothing behind.
        let _ = tokio::task::spawn_blocking(move || mcpb::prune_bundles(&root, &servers)).await;
        return bad_request(msg);
    }
    if let Err(e) = state.db.set_mcp_servers(user.id, &merged).await {
        let _ = tokio::task::spawn_blocking(move || mcpb::prune_bundles(&root, &servers)).await;
        return map_err_internal(e).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "mcp_servers.install_mcpb",
            &serde_json::json!({"name": installed_name}),
            None,
        )
        .await;

    Json(McpServersResponse { servers: merged }).into_response()
}
