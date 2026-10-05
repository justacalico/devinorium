//! Project API routes.

use std::path::PathBuf;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post, Router};
use axum::Json;
use futures::StreamExt;
use serde::{Deserialize, Serialize};

use crate::auth::session::CurrentUser;
use crate::db::{NewProject, ProjectRow};
use crate::security::paths;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/projects", get(list).post(create))
        .route("/api/projects/new", post(create_new))
        .route("/api/projects/reorder", patch(reorder))
        .route("/api/projects/:id", delete(delete_one).patch(rename))
        .route("/api/projects/:id/pin", post(pin))
        .route("/api/projects/:id/group", patch(set_group))
        .route("/api/projects/:id/threads", get(list_threads))
        .route("/api/projects/:id/icon", get(icon))
}

#[derive(Debug, Serialize)]
pub struct ProjectOut {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub position: i64,
    pub pinned: bool,
    pub is_repo: bool,
    pub branch: String,
    pub project_type: String,
    pub group_id: Option<i64>,
    /// Paired node the project lives on, if remote.
    pub node_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl ProjectOut {
    pub async fn from_row(state: &AppState, p: ProjectRow) -> Self {
        // Remote projects skip the local probe: a coincidental path match
        // would report this server's repo state for another machine.
        let (is_repo, branch) = match p.node_id {
            Some(_) => (false, String::new()),
            None => match state
                .git
                .repo_status(std::path::Path::new(&p.path), false)
                .await
            {
                Ok(s) => (s.is_repo, s.branch),
                Err(_) => (false, String::new()),
            },
        };
        Self {
            id: p.id,
            name: p.name,
            path: p.path,
            position: p.position,
            pinned: p.pinned,
            is_repo,
            branch,
            project_type: p.project_type,
            group_id: p.group_id,
            node_id: p.node_id,
            created_at: p.created_at,
            updated_at: p.updated_at,
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateProject {
    pub name: String,
    pub path: String,
    /// Paired node the path lives on; absent registers a local project.
    #[serde(default)]
    pub node_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateNewProject {
    pub name: String,
    /// Paired node to create the folder on; absent creates it locally.
    #[serde(default)]
    pub node_id: Option<String>,
}

async fn list(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(pagination): Query<crate::api::pagination::Pagination>,
) -> Response {
    let (limit, offset) = pagination.bounds();
    match state.db.list_projects(user.id, limit, offset).await {
        Ok(rows) => {
            let out: Vec<ProjectOut> = futures::stream::iter(rows.into_iter().map(|p| {
                let state = state.clone();
                async move { ProjectOut::from_row(&state, p).await }
            }))
            .buffer_unordered(8)
            .collect()
            .await;
            Json(out).into_response()
        }
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn create(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateProject>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project name is required")),
        )
            .into_response();
    }

    let path = req.path.trim();
    // An empty path is interpreted as the user's home directory so the
    // project picker can select the home root.

    if let Some(nid) = req
        .node_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        // The path lives on the satellite; validate it there.
        return create_remote(&state, &user, name, path, nid).await;
    }

    let abs = if user.is_owner {
        // Owners may register any directory.
        match resolve_and_ensure_dir(&state, path).await {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!(error = %e, path = %path, "project path resolution failed");
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("invalid project path")),
                )
                    .into_response();
            }
        }
    } else {
        match resolve_non_owner_dir(&state, &user, path).await {
            Ok(p) => p,
            Err(resp) => return *resp,
        }
    };

    insert_project(&state, user.id, name, abs, None).await
}

/// Resolve a non-owner's project path. The path must land strictly inside
/// one of the managed roots (project, worktree, or clone root); relative
/// paths resolve under the project root. Credential locations and hidden
/// names are never registrable.
async fn resolve_non_owner_dir(
    state: &AppState,
    user: &crate::db::UserRow,
    path: &str,
) -> Result<PathBuf, Box<Response>> {
    let invalid = || {
        Box::new(
            (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project path")),
            )
                .into_response(),
        )
    };
    let normalized = paths::normalize_path(path, &state.config.home_dir);
    let roots = crate::api::scope::non_owner_managed_roots(state, user.id).await;
    let project_root = crate::api::settings::project_root(state, user.id)
        .await
        .map_err(|e| Box::new(crate::api::map_err_internal(e).into_response()))?;

    let candidate = if std::path::Path::new(&normalized).is_absolute() {
        PathBuf::from(&normalized)
    } else {
        project_root.join(&normalized)
    };
    let resolved = paths::resolve(&candidate, None, None).ok_or_else(invalid)?;

    // Strictly inside a managed root: the root itself is not registrable.
    if !roots
        .iter()
        .any(|r| resolved != *r && resolved.starts_with(r))
    {
        return Err(invalid());
    }
    if paths::is_hidden_path(&resolved) || paths::has_sensitive_component(&resolved) {
        return Err(invalid());
    }

    tokio::fs::create_dir_all(&resolved)
        .await
        .map_err(|_| invalid())?;
    let abs = tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved);
    if !roots.iter().any(|r| abs != *r && abs.starts_with(r)) {
        return Err(invalid());
    }
    Ok(abs)
}

/// Create a fresh folder named after the project under the configured
/// project root and register it. The name doubles as the folder name, so it
/// must be a single plain path component.
async fn create_new(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<CreateNewProject>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project name is required")),
        )
            .into_response();
    }

    if !is_valid_folder_name(name) {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new(
                "project name is not a valid folder name",
            )),
        )
            .into_response();
    }

    if let Some(nid) = req
        .node_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return create_new_remote(&state, &user, name, nid).await;
    }

    let root = match crate::api::settings::project_root(&state, user.id).await {
        Ok(r) => r,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let resolved = match paths::resolve(&root.join(name), None, None) {
        Some(r) => r,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project path")),
            )
                .into_response()
        }
    };

    // A pre-existing symlink at root/name could resolve outside the root;
    // refuse to register that as a project.
    if !paths::is_within(&resolved, &root) {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid project path")),
        )
            .into_response();
    }

    // Reject duplicates before creating the folder so a 409 does not leave
    // a stray directory behind.
    if let Some(path_str) = resolved.to_str() {
        if let Some(resp) = project_conflict(&state, user.id, name, path_str).await {
            return resp;
        }
    }

    if let Err(e) = tokio::fs::create_dir_all(&resolved).await {
        tracing::warn!(error = %e, path = %resolved.display(), "project folder creation failed");
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("cannot create project folder")),
        )
            .into_response();
    }

    let abs = tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved);
    // Canonicalization follows symlinks, so re-check containment: a symlink
    // swapped in after the first check must not land the project outside.
    if !paths::is_within(&abs, &root) {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid project path")),
        )
            .into_response();
    }
    insert_project(&state, user.id, name, abs, None).await
}

/// Check that `name` works as a single folder name: no separators, no
/// control characters, no `.`/`..` components, and none of the protected
/// hidden or sensitive names.
fn is_valid_folder_name(name: &str) -> bool {
    if name.is_empty()
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(|c| c.is_control())
        || paths::is_hidden_name(name)
        || paths::is_sensitive_name(name)
    {
        return false;
    }
    std::path::Path::new(name)
        .components()
        .all(|c| matches!(c, std::path::Component::Normal(_)))
}

/// Return a 409 response when `name` or `path` is already registered for
/// this user, or `None` when the project can be created.
async fn project_conflict(
    state: &AppState,
    user_id: i64,
    name: &str,
    path: &str,
) -> Option<Response> {
    if state
        .db
        .get_project_by_path(user_id, path)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return Some(
            (
                StatusCode::CONFLICT,
                Json(crate::api::ApiError::new("project path already exists")),
            )
                .into_response(),
        );
    }

    if state
        .db
        .get_project_by_name(user_id, name)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return Some(
            (
                StatusCode::CONFLICT,
                Json(crate::api::ApiError::new("project name already exists")),
            )
                .into_response(),
        );
    }

    None
}

/// Insert a project once `name` and the canonical absolute `abs` path are
/// validated, translating duplicate races into 409s.
async fn insert_project(
    state: &AppState,
    user_id: i64,
    name: &str,
    abs: PathBuf,
    node_id: Option<String>,
) -> Response {
    let path_str = match abs.to_str() {
        Some(s) => s.to_string(),
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid project path encoding")),
            )
                .into_response()
        }
    };

    if let Some(resp) = project_conflict(state, user_id, name, &path_str).await {
        return resp;
    }

    let position = match state.db.next_project_position(user_id).await {
        Ok(p) => p,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let project_type = if node_id.is_some() {
        "other"
    } else {
        crate::projects::detect::detect_project_type(&abs)
    };

    let new = NewProject {
        user_id,
        name: name.to_string(),
        path: path_str,
        position,
        project_type: project_type.to_string(),
        node_id,
    };

    match state.db.create_project(new).await {
        Ok(p) => {
            let out = ProjectOut::from_row(state, p).await;
            (StatusCode::CREATED, Json(out)).into_response()
        }
        Err(e) => {
            // A duplicate name or path can race the pre-checks above.
            if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
                if db_err.is_unique_violation() {
                    return (
                        StatusCode::CONFLICT,
                        Json(crate::api::ApiError::new(
                            "project with this name or path already exists",
                        )),
                    )
                        .into_response();
                }
            }
            crate::api::map_err_internal(e).into_response()
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct ReorderProjects {
    pub project_ids: Vec<i64>,
}

#[derive(Debug, Deserialize)]
pub struct RenameProject {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct PinProject {
    pub pinned: bool,
}

async fn rename(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<RenameProject>,
) -> Response {
    let name = req.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project name is required")),
        )
            .into_response();
    }

    // Verify ownership and fetch the current row.
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    if name == project.name {
        let out = ProjectOut::from_row(&state, project).await;
        return Json(out).into_response();
    }

    // Prevent duplicate names for the same user.
    if state
        .db
        .get_project_by_name(user.id, name)
        .await
        .ok()
        .flatten()
        .is_some()
    {
        return (
            StatusCode::CONFLICT,
            Json(crate::api::ApiError::new("project name already exists")),
        )
            .into_response();
    }

    if let Err(e) = state.db.rename_project(id, user.id, name).await {
        if let Some(sqlx::Error::Database(db_err)) = e.downcast_ref::<sqlx::Error>() {
            if db_err.is_unique_violation() {
                return (
                    StatusCode::CONFLICT,
                    Json(crate::api::ApiError::new(
                        "project with this name already exists",
                    )),
                )
                    .into_response();
            }
        }
        return crate::api::map_err_internal(e).into_response();
    }

    match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => Json(ProjectOut::from_row(&state, p).await).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn pin(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<PinProject>,
) -> Response {
    match state.db.get_project(id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    if let Err(e) = state.db.set_project_pinned(id, user.id, req.pinned).await {
        return crate::api::map_err_internal(e).into_response();
    }

    match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => Json(ProjectOut::from_row(&state, p).await).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

#[derive(Debug, Deserialize)]
pub struct SetProjectGroup {
    /// `null` ungroups the project.
    pub group_id: Option<i64>,
}

async fn set_group(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<SetProjectGroup>,
) -> Response {
    match state.db.get_project(id, user.id).await {
        Ok(Some(_)) => {}
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    }

    if let Some(gid) = req.group_id {
        match state.db.get_project_group(gid, user.id).await {
            Ok(Some(_)) => {}
            Ok(None) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(crate::api::ApiError::new("group not found")),
                )
                    .into_response();
            }
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        }
    }

    if let Err(e) = state.db.set_project_group(id, user.id, req.group_id).await {
        return crate::api::map_err_internal(e).into_response();
    }

    match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => Json(ProjectOut::from_row(&state, p).await).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

async fn reorder(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<ReorderProjects>,
) -> Response {
    if req.project_ids.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("project_ids is required")),
        )
            .into_response();
    }

    match state
        .db
        .update_project_positions(user.id, &req.project_ids)
        .await
    {
        Ok(()) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => {
            tracing::warn!(error = %e, user_id = user.id, "project reorder failed");
            (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new(e.to_string())),
            )
                .into_response()
        }
    }
}

async fn delete_one(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    // The node row must be captured before the delete: bound projects
    // lose their machine binding the moment the row is gone, and remote
    // worktrees need it to clean up on the satellite.
    let project = state.db.get_project(id, user.id).await.ok().flatten();
    let project_node = match &project {
        Some(p) => crate::node_client::node_for_project(&state, p).await,
        None => None,
    };
    let project_path = project.map(|p| PathBuf::from(p.path));

    // Threads are deleted in the same transaction as the project, so the
    // returned rows are exactly the ones that went away.
    let threads = match state.db.delete_project(id, user.id).await {
        Ok(t) => t,
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    // Stop every run first so their cancel grace periods overlap, then wait
    // and clean up each thread's managed worktree.
    for thread in &threads {
        let _ = state.thread_runner.stop(&thread.id).await;
    }
    for thread in &threads {
        state
            .thread_runner
            .wait_finished(&thread.id, std::time::Duration::from_secs(15))
            .await;
        crate::api::threads::worktree::cleanup_thread_worktree(
            &state,
            thread,
            project_path.as_deref(),
            project_node.as_ref(),
        )
        .await;
    }
    StatusCode::NO_CONTENT.into_response()
}

/// The project's resolved app icon, sent as base64 like message attachments.
/// 404 when the project has no icon so the client can use its local fallback.
async fn icon(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
) -> Response {
    let project = match state.db.get_project(id, user.id).await {
        Ok(Some(p)) => p,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                Json(crate::api::ApiError::new("not found")),
            )
                .into_response()
        }
        Err(e) => return crate::api::map_err_internal(e).into_response(),
    };

    let node = match crate::node_client::bound_node(&state, &project).await {
        Ok(n) => n,
        Err(e) => return crate::node_client::node_bad_gateway(e.to_string()),
    };
    if let Some(node) = node {
        if !user.is_owner {
            return (
                StatusCode::FORBIDDEN,
                Json(crate::api::ApiError::new("paired machines are owner-only")),
            )
                .into_response();
        }
        return icon_remote(&state, &project, &node).await;
    }

    // Discovery walks the filesystem; keep it off the async executor.
    let path = project.path.clone();
    let resolved = tokio::task::spawn_blocking(move || {
        crate::projects::icon::resolve_and_load(std::path::Path::new(&path))
    })
    .await;
    match resolved.unwrap_or(None) {
        Some((bytes, mime)) => {
            use base64::Engine;
            Json(serde_json::json!({
                "mime": mime,
                "size": bytes.len(),
                "base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
            }))
            .into_response()
        }
        None => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("no icon")),
        )
            .into_response(),
    }
}

async fn list_threads(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<i64>,
    Query(pagination): Query<crate::api::pagination::Pagination>,
) -> Response {
    let (limit, offset) = pagination.bounds();
    match state
        .db
        .list_threads_for_project(id, user.id, limit, offset)
        .await
    {
        Ok(rows) => Json(
            rows.into_iter()
                .map(crate::api::threads::ThreadOut::from)
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => crate::api::map_err_internal(e).into_response(),
    }
}

/// Resolve the user-supplied path, create the directory if it doesn't exist,
/// and return the canonical absolute path. Paths are resolved relative to the
/// user's home directory unless they are absolute.
async fn resolve_and_ensure_dir(state: &AppState, path: &str) -> anyhow::Result<PathBuf> {
    let path = paths::normalize_path(path, &state.config.home_dir);

    if std::path::Path::new(&path).is_absolute() {
        let resolved = paths::resolve(std::path::Path::new(&path), None, None)
            .ok_or_else(|| anyhow::anyhow!("invalid project path"))?;
        tokio::fs::create_dir_all(&resolved).await?;
        return Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved));
    }

    // Treat `.` and empty paths as the home directory so the user can add the
    // home root from the folder picker.
    if path.is_empty() || path == "." {
        let resolved = state.config.home_dir.clone();
        tokio::fs::create_dir_all(&resolved).await?;
        return Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved));
    }

    // Reject `..` in any path component to prevent traversal through symlinks.
    if path.split(['/', '\\']).any(|c| c == "..") {
        return Err(anyhow::anyhow!("path traversal is not allowed"));
    }

    // Resolve relative to home. Unlike the file manager, project creation allows
    // absolute paths, so a symlink inside the home directory that points outside
    // is also accepted.
    let candidate = state.config.home_dir.join(&path);
    let resolved = paths::resolve(&candidate, Some(&state.config.home_dir), None)
        .ok_or_else(|| anyhow::anyhow!("invalid project path"))?;

    // Ensure the directory exists.
    tokio::fs::create_dir_all(&resolved).await?;

    // Canonicalize so the stored path is stable.
    Ok(tokio::fs::canonicalize(&resolved).await.unwrap_or(resolved))
}

/// Fetch a remote project's icon: stat the usual candidate names in one
/// call, then read the first hit. `None` fields map to the same 404 the
/// local handler returns.
async fn icon_remote(
    state: &AppState,
    project: &ProjectRow,
    node: &crate::db::federation_nodes::FederationNodeRow,
) -> Response {
    let Some(client) = crate::node_client::NodeClient::for_node(state, node) else {
        return crate::node_client::node_bad_gateway("node unreachable");
    };
    const CANDIDATES: &[&str] = &[
        "favicon.svg",
        "favicon.png",
        "favicon.ico",
        "icon.svg",
        "icon.png",
        "logo.svg",
        "logo.png",
        "public/favicon.svg",
        "public/favicon.png",
        "public/icon.svg",
        "public/icon.png",
        "public/logo.svg",
        "public/logo.png",
    ];
    let stats = client
        .fs_stat(
            Some(&project.path),
            &CANDIDATES.iter().map(|c| c.to_string()).collect::<Vec<_>>(),
        )
        .await
        .unwrap_or_default();
    for name in CANDIDATES {
        if !stats
            .get(*name)
            .map(|s| s.exists && !s.is_dir)
            .unwrap_or(false)
        {
            continue;
        }
        if let Some((mime, bytes)) = client.fs_read(&project.path, name).await {
            if bytes.len() <= 4 * 1024 * 1024 {
                use base64::Engine;
                return Json(serde_json::json!({
                    "mime": mime,
                    "size": bytes.len(),
                    "base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
                }))
                .into_response();
            }
        }
    }
    (
        StatusCode::NOT_FOUND,
        Json(crate::api::ApiError::new("no icon")),
    )
        .into_response()
}

/// Register a project whose path lives on a paired node. Relative paths
/// resolve under the satellite's home directory; absolute paths are taken
/// as-is.
async fn create_remote(
    state: &AppState,
    user: &crate::db::UserRow,
    name: &str,
    path: &str,
    node_id: &str,
) -> Response {
    let invalid = || {
        (
            StatusCode::BAD_REQUEST,
            Json(crate::api::ApiError::new("invalid project path")),
        )
            .into_response()
    };
    if !user.is_owner {
        return (
            StatusCode::FORBIDDEN,
            Json(crate::api::ApiError::new("paired machines are owner-only")),
        )
            .into_response();
    }
    if path.trim().is_empty() {
        return invalid();
    }
    let node = match state.db.get_federation_node(node_id).await {
        Ok(Some(n)) => n,
        _ => return invalid(),
    };
    let Some(client) = crate::node_client::NodeClient::for_node(state, &node) else {
        return crate::node_client::node_bad_gateway("node unreachable");
    };
    // Create the directory if missing, then take the node's canonical
    // spelling as the project path.
    let raw = path.to_string();
    let exists = client
        .fs_stat(None, std::slice::from_ref(&raw))
        .await
        .ok()
        .and_then(|mut m| m.remove(&raw));
    let abs = match exists {
        Some(s) if s.is_dir => s
            .canonical
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(path)),
        Some(s) if s.exists => return invalid(),
        Some(_) | None => {
            if client.fs_mkdir(None, path).await.is_err() {
                return crate::node_client::node_bad_gateway("cannot create project folder");
            }
            client
                .fs_stat(None, std::slice::from_ref(&raw))
                .await
                .ok()
                .and_then(|mut m| m.remove(&raw))
                .and_then(|s| s.canonical.map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from(path))
        }
    };
    insert_project(state, user.id, name, abs, Some(node.id.clone())).await
}

/// Create `<node home>/.devinorium/projects/<name>` on the satellite and
/// register it.
async fn create_new_remote(
    state: &AppState,
    user: &crate::db::UserRow,
    name: &str,
    node_id: &str,
) -> Response {
    if !user.is_owner {
        return (
            StatusCode::FORBIDDEN,
            Json(crate::api::ApiError::new("paired machines are owner-only")),
        )
            .into_response();
    }
    let node = match state.db.get_federation_node(node_id).await {
        Ok(Some(n)) => n,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(crate::api::ApiError::new("invalid node_id")),
            )
                .into_response()
        }
    };
    let Some(client) = crate::node_client::NodeClient::for_node(state, &node) else {
        return crate::node_client::node_bad_gateway("node unreachable");
    };
    let rel = format!(".devinorium/projects/{name}");
    if client.fs_mkdir(None, &rel).await.is_err() {
        return crate::node_client::node_bad_gateway("cannot create project folder");
    }
    let abs = client
        .fs_stat(None, std::slice::from_ref(&rel))
        .await
        .ok()
        .and_then(|mut m| m.remove(&rel))
        .and_then(|s| s.canonical.map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from(&rel));
    insert_project(state, user.id, name, abs, Some(node.id.clone())).await
}
