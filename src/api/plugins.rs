//! Plugin management API.
//!
//! Owner-only throughout: installing a plugin hands the server a bundle
//! that can register shell commands (hooks) and MCP servers, so it carries
//! the same trust level as the MCP server list. `GET /api/plugins` lists
//! the user-scope plugins in `~/.config/devinorium/plugins`, optionally
//! joined by the project-scope ones under `?cwd=`'s `.devinorium/plugins`.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put, Router};
use axum::Json;
use serde::Deserialize;

use crate::api::{bad_request, ApiError};
use crate::auth::session::CurrentUser;
use crate::plugins;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/plugins", get(list_plugins))
        .route("/api/plugins/install", post(install_plugin))
        .route("/api/plugins/:name/enabled", put(set_plugin_enabled))
        .route("/api/plugins/:name/update", post(update_plugin))
        .route("/api/plugins/:name", delete(uninstall_plugin))
}

fn owner_only(user: &crate::db::UserRow) -> Option<Response> {
    if user.is_owner {
        None
    } else {
        Some((StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response())
    }
}

#[derive(Debug, Deserialize)]
struct ListQuery {
    /// Optional working directory; its `.devinorium/plugins` entries are
    /// included flagged `source: "project"`.
    cwd: Option<String>,
}

async fn list_plugins(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ListQuery>,
) -> Response {
    if let Some(resp) = owner_only(&user) {
        return resp;
    }
    let cwd = q.cwd.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let cwd = match cwd {
        None => None,
        Some(c) => {
            let normalized = crate::security::paths::normalize_path(c, &state.config.home_dir);
            let p = std::path::PathBuf::from(&normalized);
            match tokio::fs::canonicalize(&p).await {
                Ok(c) if c.is_dir() => Some(c),
                _ => {
                    return bad_request("cwd is not an existing directory").into_response();
                }
            }
        }
    };
    let found = plugins::discover_plugins(cwd.as_deref(), &state.config.home_dir).await;
    let mut infos = Vec::with_capacity(found.len());
    for p in &found {
        infos.push(plugins::plugin_info(p).await);
    }
    Json(serde_json::json!({ "plugins": infos })).into_response()
}

#[derive(Debug, Deserialize)]
struct InstallRequest {
    /// A git URL or an absolute local directory path.
    source: String,
}

async fn install_plugin(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<InstallRequest>,
) -> Response {
    if let Some(resp) = owner_only(&user) {
        return resp;
    }
    match plugins::install(&state.config.home_dir, &req.source).await {
        Ok(names) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "plugin.install",
                    &serde_json::json!({"source": req.source, "plugins": names}),
                    None,
                )
                .await;
            Json(serde_json::json!({ "installed": names })).into_response()
        }
        Err(msg) => bad_request(msg),
    }
}

#[derive(Debug, Deserialize)]
struct EnabledRequest {
    enabled: bool,
}

async fn set_plugin_enabled(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(name): Path<String>,
    Json(req): Json<EnabledRequest>,
) -> Response {
    if let Some(resp) = owner_only(&user) {
        return resp;
    }
    match plugins::set_enabled(&state.config.home_dir, &name, req.enabled).await {
        Ok(()) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "plugin.enabled",
                    &serde_json::json!({"name": name, "enabled": req.enabled}),
                    None,
                )
                .await;
            Json(serde_json::json!({"ok": true})).into_response()
        }
        Err(msg) => bad_request(msg),
    }
}

async fn update_plugin(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(name): Path<String>,
) -> Response {
    if let Some(resp) = owner_only(&user) {
        return resp;
    }
    match plugins::update(&state.config.home_dir, &name).await {
        Ok(output) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "plugin.update",
                    &serde_json::json!({"name": name}),
                    None,
                )
                .await;
            Json(serde_json::json!({"ok": true, "output": output})).into_response()
        }
        Err(msg) => bad_request(msg),
    }
}

async fn uninstall_plugin(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(name): Path<String>,
) -> Response {
    if let Some(resp) = owner_only(&user) {
        return resp;
    }
    match plugins::uninstall(&state.config.home_dir, &name).await {
        Ok(()) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "plugin.uninstall",
                    &serde_json::json!({"name": name}),
                    None,
                )
                .await;
            Json(serde_json::json!({"ok": true})).into_response()
        }
        Err(msg) if msg.starts_with("no installed plugin") => {
            (StatusCode::NOT_FOUND, Json(ApiError::new(msg))).into_response()
        }
        Err(msg) => bad_request(msg),
    }
}
