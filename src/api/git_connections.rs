//! Git host connection settings API.

use axum::extract::{Query, Request, State};
use axum::http::StatusCode;
use axum::middleware::{from_fn, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, Router};
use axum::Json;
use serde::Deserialize;

use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::git::{GitConnection, GitHost, MergeRequestAction, RemoteError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/git-connections", get(list))
        .route("/api/git-connections/gitlab", post(login_gitlab))
        .route("/api/git-connections/gitlab", delete(logout_gitlab))
        .route("/api/git-connections/gitlab/proxy", get(gitlab_proxy))
        .route(
            "/api/git-connections/gitlab/pipelines/jobs",
            get(gitlab_pipeline_jobs),
        )
        .route(
            "/api/git-connections/gitlab/pipelines/jobs/logs",
            get(gitlab_job_log),
        )
        .route(
            "/api/git-connections/gitlab/pipelines",
            get(gitlab_pipelines),
        )
        .route(
            "/api/git-connections/gitlab/merge-requests/actions",
            post(gitlab_merge_request_action),
        )
        .route("/api/git-connections/github", post(login_github))
        .route("/api/git-connections/github", delete(logout_github))
        .route("/api/git-connections/github/proxy", get(github_proxy))
        .route(
            "/api/git-connections/github/pipelines/jobs",
            get(github_pipeline_jobs),
        )
        .route(
            "/api/git-connections/github/pipelines/jobs/logs",
            get(github_job_log),
        )
        .route(
            "/api/git-connections/github/pipelines",
            get(github_pipelines),
        )
        .route(
            "/api/git-connections/github/merge-requests/actions",
            post(github_pull_request_action),
        )
        .route_layer(from_fn(owner_only))
}

/// Git host connections drive the operator's shared CLI identity, so
/// every route here is owner-only.
async fn owner_only(req: Request, next: Next) -> Response {
    match req.extensions().get::<CurrentUser>() {
        Some(CurrentUser(user)) if user.is_owner => next.run(req).await,
        _ => (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response(),
    }
}

fn connection_json(host: GitHost, status: crate::git::GitHostStatus) -> Response {
    Json(GitConnection {
        id: host.id(),
        name: host.display_name(),
        enabled: true,
        available: true,
        authed: true,
        account: status.account,
        host: Some(status.host),
        coming_soon: false,
    })
    .into_response()
}

fn remote_error(e: RemoteError, host: GitHost) -> Response {
    match e {
        RemoteError::GitLabNotAvailable | RemoteError::GitHubNotAvailable => {
            let msg = match host {
                GitHost::GitLab => "gitlab cli is not installed",
                GitHost::GitHub => "github cli is not installed",
            };
            (StatusCode::NOT_FOUND, Json(ApiError::new(msg))).into_response()
        }
        e => (e.status_code(), Json(ApiError::new(e.to_string()))).into_response(),
    }
}

fn optional_hostname(raw: Option<&String>) -> Option<&str> {
    raw.map(String::as_str).filter(|s| !s.is_empty())
}

#[derive(Debug, Deserialize)]
pub struct HostRequest {
    pub hostname: Option<String>,
}

async fn list(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    let connections = state.git_remote.connections(user.id).await;
    Json(connections).into_response()
}

async fn login_gitlab(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<HostRequest>,
) -> Response {
    match state
        .git_remote
        .login_gitlab(user.id, optional_hostname(req.hostname.as_ref()))
        .await
    {
        Ok(status) => connection_json(GitHost::GitLab, status),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn logout_gitlab(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<HostRequest>,
) -> Response {
    match state
        .git_remote
        .logout_gitlab(user.id, optional_hostname(req.hostname.as_ref()))
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn login_github(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<HostRequest>,
) -> Response {
    match state
        .git_remote
        .login_github(user.id, optional_hostname(req.hostname.as_ref()))
        .await
    {
        Ok(status) => connection_json(GitHost::GitHub, status),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

async fn logout_github(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<HostRequest>,
) -> Response {
    match state
        .git_remote
        .logout_github(user.id, optional_hostname(req.hostname.as_ref()))
        .await
    {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

#[derive(Debug, Deserialize)]
pub struct ProxyQuery {
    pub path: String,
    pub hostname: Option<String>,
}

async fn gitlab_proxy(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ProxyQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("gitlab.com");

    match state
        .git_remote
        .gitlab_api(user.id, hostname, &q.path)
        .await
    {
        Ok(output) => match serde_json::from_str::<serde_json::Value>(&output) {
            Ok(v) => Json(v).into_response(),
            Err(e) => {
                tracing::warn!("gitlab proxy returned non-JSON: {e}");
                (
                    StatusCode::BAD_GATEWAY,
                    Json(ApiError::new("GitLab returned invalid JSON")),
                )
                    .into_response()
            }
        },
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn github_proxy(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<ProxyQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("github.com");

    match state
        .git_remote
        .github_api(user.id, hostname, &q.path)
        .await
    {
        Ok(output) => match serde_json::from_str::<serde_json::Value>(&output) {
            Ok(v) => Json(v).into_response(),
            Err(e) => {
                tracing::warn!("github proxy returned non-JSON: {e}");
                (
                    StatusCode::BAD_GATEWAY,
                    Json(ApiError::new("GitHub returned invalid JSON")),
                )
                    .into_response()
            }
        },
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

#[derive(Debug, Deserialize)]
pub struct PipelinesQuery {
    pub project: String,
    pub iid: i64,
    pub hostname: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PipelineJobsQuery {
    pub project: String,
    pub pipeline_id: i64,
    pub hostname: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct JobLogQuery {
    pub project: String,
    pub job_id: i64,
    pub hostname: Option<String>,
}

fn bad_request(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(ApiError::new(msg))).into_response()
}

async fn gitlab_pipeline_jobs(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<PipelineJobsQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("gitlab.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.pipeline_id <= 0 {
        return bad_request("pipeline_id must be positive");
    }

    match state
        .git_remote
        .gitlab_pipeline_jobs(user.id, hostname, &q.project, q.pipeline_id)
        .await
    {
        Ok(jobs) => Json(jobs).into_response(),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn gitlab_job_log(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<JobLogQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("gitlab.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.job_id <= 0 {
        return bad_request("job_id must be positive");
    }

    match state
        .git_remote
        .gitlab_job_log(user.id, hostname, &q.project, q.job_id)
        .await
    {
        Ok(log) => Json(log).into_response(),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn gitlab_pipelines(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<PipelinesQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("gitlab.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.iid <= 0 {
        return bad_request("iid must be positive");
    }

    match state
        .git_remote
        .gitlab_pipelines(user.id, hostname, &q.project, q.iid)
        .await
    {
        Ok(pipelines) => Json(pipelines).into_response(),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn github_pipeline_jobs(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<PipelineJobsQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("github.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.pipeline_id <= 0 {
        return bad_request("pipeline_id must be positive");
    }

    match state
        .git_remote
        .github_pipeline_jobs(user.id, hostname, &q.project, q.pipeline_id)
        .await
    {
        Ok(jobs) => Json(jobs).into_response(),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

async fn github_job_log(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<JobLogQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("github.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.job_id <= 0 {
        return bad_request("job_id must be positive");
    }

    match state
        .git_remote
        .github_job_log(user.id, hostname, &q.project, q.job_id)
        .await
    {
        Ok(log) => Json(log).into_response(),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

async fn github_pipelines(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<PipelinesQuery>,
) -> Response {
    let hostname = optional_hostname(q.hostname.as_ref()).unwrap_or("github.com");

    if q.project.is_empty() {
        return bad_request("project is required");
    }
    if q.iid <= 0 {
        return bad_request("iid must be positive");
    }

    match state
        .git_remote
        .github_pipelines(user.id, hostname, &q.project, q.iid)
        .await
    {
        Ok(pipelines) => Json(pipelines).into_response(),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}

#[derive(Debug, Deserialize)]
pub struct MergeRequestActionRequest {
    pub project: String,
    pub iid: i64,
    pub action: MergeRequestAction,
    pub hostname: Option<String>,
}

async fn gitlab_merge_request_action(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<MergeRequestActionRequest>,
) -> Response {
    let hostname = optional_hostname(req.hostname.as_ref()).unwrap_or("gitlab.com");

    if req.project.is_empty() {
        return bad_request("project is required");
    }
    if req.iid <= 0 {
        return bad_request("iid must be positive");
    }

    tracing::info!(
        user_id = user.id,
        project = %req.project,
        iid = req.iid,
        action = ?req.action,
        "gitlab merge request action"
    );

    match state
        .git_remote
        .gitlab_merge_request_action(user.id, hostname, &req.project, req.iid, req.action)
        .await
    {
        Ok(mr) => Json(mr).into_response(),
        Err(e) => remote_error(e, GitHost::GitLab),
    }
}

async fn github_pull_request_action(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<MergeRequestActionRequest>,
) -> Response {
    let hostname = optional_hostname(req.hostname.as_ref()).unwrap_or("github.com");

    if req.project.is_empty() {
        return bad_request("project is required");
    }
    if req.iid <= 0 {
        return bad_request("iid must be positive");
    }

    tracing::info!(
        user_id = user.id,
        project = %req.project,
        iid = req.iid,
        action = ?req.action,
        "github pull request action"
    );

    match state
        .git_remote
        .github_pull_request_action(user.id, hostname, &req.project, req.iid, req.action)
        .await
    {
        Ok(pr) => Json(pr).into_response(),
        Err(e) => remote_error(e, GitHost::GitHub),
    }
}
