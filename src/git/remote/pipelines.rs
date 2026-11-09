//! CI/CD pipeline and workflow run fetching for GitLab and GitHub.

use chrono::{DateTime, Utc};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use super::parse::validate_project_path;
use super::{GitRemoteService, RemoteError};

/// A single CI/CD pipeline or workflow run for a merge/pull request.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RemotePipeline {
    pub id: i64,
    pub status: String,
    pub name: String,
    pub web_url: String,
    pub ref_name: String,
    pub created_at: String,
    pub updated_at: String,
}

/// A single job inside a pipeline or workflow run.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RemotePipelineJob {
    pub id: i64,
    pub name: String,
    pub status: String,
    pub stage: String,
    pub web_url: String,
    pub started_at: String,
    pub finished_at: String,
    pub duration: f64,
}

/// A job and its raw log output.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RemoteJobLog {
    pub job: RemotePipelineJob,
    pub trace: String,
}

impl GitRemoteService {
    /// Fetch the CI/CD pipelines for a GitLab merge request.
    ///
    /// [project_path] is the raw "group/project" style path and is encoded
    /// before being passed to `glab api`. The list is sorted with the most
    /// recently updated pipeline first.
    pub async fn gitlab_pipelines(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
    ) -> Result<Vec<RemotePipeline>, RemoteError> {
        validate_project_path(project_path)?;
        if iid <= 0 {
            return Err(RemoteError::StatusFailed("iid must be positive".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path =
            format!("projects/{encoded_project}/merge_requests/{iid}/pipelines?per_page=100");

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let pipelines: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid pipeline json: {e}"))
        })?;

        let mut pipelines: Vec<RemotePipeline> = pipelines
            .into_iter()
            .map(parse_pipeline)
            .collect::<Result<Vec<_>, _>>()?;
        pipelines.sort_by(|a, b| {
            let a_time = parse_timestamp(&a.updated_at);
            let b_time = parse_timestamp(&b.updated_at);
            b_time.cmp(&a_time)
        });
        Ok(pipelines)
    }

    /// Fetch the CI/CD jobs for a GitLab pipeline.
    ///
    /// [project_path] is the raw "group/project" style path and is encoded
    /// before being passed to `glab api`.
    pub async fn gitlab_pipeline_jobs(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        pipeline_id: i64,
    ) -> Result<Vec<RemotePipelineJob>, RemoteError> {
        validate_project_path(project_path)?;
        if pipeline_id <= 0 {
            return Err(RemoteError::StatusFailed(
                "pipeline id must be positive".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!("projects/{encoded_project}/pipelines/{pipeline_id}/jobs?per_page=100");

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let jobs: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid job json: {e}"))
        })?;

        jobs.into_iter()
            .map(parse_pipeline_job)
            .collect::<Result<Vec<_>, _>>()
    }

    /// Fetch a single CI/CD job for a GitLab project.
    pub async fn gitlab_pipeline_job(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<RemotePipelineJob, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!("projects/{encoded_project}/jobs/{job_id}");

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid job json: {e}"))
        })?;
        parse_pipeline_job(value)
    }

    /// Fetch the raw trace log for a single GitLab CI/CD job.
    ///
    /// A missing trace is treated as an empty string so jobs that have not
    /// started yet do not surface as an error.
    pub async fn gitlab_job_trace(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<String, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!("projects/{encoded_project}/jobs/{job_id}/trace");

        match self.gitlab_api(user_id, hostname, &path).await {
            Ok(trace) => Ok(trace),
            Err(RemoteError::StatusFailed(ref msg)) if is_trace_not_found(msg) => Ok(String::new()),
            Err(e) => Err(e),
        }
    }

    /// Fetch the trace and status for a single GitLab CI/CD job.
    pub async fn gitlab_job_log(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<RemoteJobLog, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let (job, trace) = futures::future::try_join(
            self.gitlab_pipeline_job(user_id, hostname, project_path, job_id),
            self.gitlab_job_trace(user_id, hostname, project_path, job_id),
        )
        .await?;
        Ok(RemoteJobLog { job, trace })
    }

    /// Fetch the GitHub Actions workflow runs for a pull request.
    ///
    /// GitHub has no per-PR pipeline list; the runs are the ones recorded
    /// against the PR's head commit. The list is sorted with the most
    /// recently updated run first.
    pub async fn github_pipelines(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
    ) -> Result<Vec<RemotePipeline>, RemoteError> {
        validate_project_path(project_path)?;
        if iid <= 0 {
            return Err(RemoteError::StatusFailed("iid must be positive".into()));
        }

        let repo = Self::github_repo_path(project_path)?;
        let output = self
            .github_api(user_id, hostname, &format!("{repo}/pulls/{iid}"))
            .await?;
        let pr: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid pull request json: {e}"))
        })?;
        let head_sha = pr["head"]["sha"].as_str().unwrap_or("");
        if head_sha.is_empty() {
            return Ok(Vec::new());
        }

        let path = format!("{repo}/actions/runs?head_sha={head_sha}&per_page=30");
        let output = self.github_api(user_id, hostname, &path).await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid workflow json: {e}"))
        })?;
        let runs = value["workflow_runs"]
            .as_array()
            .cloned()
            .unwrap_or_default();

        let mut pipelines: Vec<RemotePipeline> = runs
            .into_iter()
            .map(parse_workflow_run)
            .collect::<Result<Vec<_>, _>>()?;
        pipelines.sort_by(|a, b| {
            let a_time = parse_timestamp(&a.updated_at);
            let b_time = parse_timestamp(&b.updated_at);
            b_time.cmp(&a_time)
        });
        Ok(pipelines)
    }

    /// Fetch the jobs for a GitHub Actions workflow run.
    pub async fn github_pipeline_jobs(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        pipeline_id: i64,
    ) -> Result<Vec<RemotePipelineJob>, RemoteError> {
        validate_project_path(project_path)?;
        if pipeline_id <= 0 {
            return Err(RemoteError::StatusFailed(
                "pipeline id must be positive".into(),
            ));
        }

        let repo = Self::github_repo_path(project_path)?;
        let path = format!("{repo}/actions/runs/{pipeline_id}/jobs?per_page=100");

        let output = self.github_api(user_id, hostname, &path).await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid job json: {e}"))
        })?;
        let jobs = value["jobs"].as_array().cloned().unwrap_or_default();

        jobs.into_iter()
            .map(parse_workflow_job)
            .collect::<Result<Vec<_>, _>>()
    }

    /// Fetch a single GitHub Actions job for a repository.
    pub async fn github_pipeline_job(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<RemotePipelineJob, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let repo = Self::github_repo_path(project_path)?;
        let output = self
            .github_api(user_id, hostname, &format!("{repo}/actions/jobs/{job_id}"))
            .await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid job json: {e}"))
        })?;
        parse_workflow_job(value)
    }

    /// Fetch the raw log for a single GitHub Actions job.
    ///
    /// `gh api` follows the endpoint's redirect to the log archive and
    /// returns plain text. A missing log is treated as an empty string so
    /// queued jobs that have not produced output yet are not an error.
    pub async fn github_job_trace(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<String, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let repo = Self::github_repo_path(project_path)?;
        let path = format!("{repo}/actions/jobs/{job_id}/logs");

        match self.github_api(user_id, hostname, &path).await {
            Ok(trace) => Ok(trace),
            Err(RemoteError::StatusFailed(ref msg)) if is_trace_not_found(msg) => Ok(String::new()),
            Err(e) => Err(e),
        }
    }

    /// Fetch the log and status for a single GitHub Actions job.
    pub async fn github_job_log(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        job_id: i64,
    ) -> Result<RemoteJobLog, RemoteError> {
        validate_project_path(project_path)?;
        if job_id <= 0 {
            return Err(RemoteError::StatusFailed("job id must be positive".into()));
        }

        let (job, trace) = futures::future::try_join(
            self.github_pipeline_job(user_id, hostname, project_path, job_id),
            self.github_job_trace(user_id, hostname, project_path, job_id),
        )
        .await?;
        Ok(RemoteJobLog { job, trace })
    }
}

/// Whether a CLI error means the job log does not exist yet. `glab` writes
/// `404 ...` to stderr while `gh` reports `Not Found (HTTP 404)` and prints
/// the `{"status":"404"}` JSON body to stdout.
fn is_trace_not_found(msg: &str) -> bool {
    msg.lines().map(str::trim).any(|line| {
        line.starts_with("404 ")
            || line.contains(": 404 ")
            || line.contains(" 404 ")
            || line.contains("HTTP 404")
            || line.contains("\"status\":\"404\"")
            || line.contains("\"status\": \"404\"")
    })
}

fn parse_timestamp(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(DateTime::UNIX_EPOCH)
}

fn parse_pipeline(value: serde_json::Value) -> Result<RemotePipeline, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

    if id <= 0 {
        return Err(RemoteError::StatusFailed(
            "gitlab returned an invalid pipeline id".into(),
        ));
    }

    let status = value["status"]
        .as_str()
        .or_else(|| {
            value
                .get("detailed_status")
                .and_then(|v| v.get("group"))
                .and_then(|v| v.as_str())
        })
        .unwrap_or("unknown");

    let name = value["name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| value["ref"].as_str())
        .unwrap_or(status);

    let web_url = value["web_url"].as_str().unwrap_or("");
    let ref_name = value["ref"].as_str().unwrap_or("");
    let created_at = value["created_at"].as_str().unwrap_or("");
    let updated_at = value["updated_at"].as_str().unwrap_or("");

    Ok(RemotePipeline {
        id,
        status: status.to_string(),
        name: name.to_string(),
        web_url: web_url.to_string(),
        ref_name: ref_name.to_string(),
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
    })
}

fn parse_pipeline_job(value: serde_json::Value) -> Result<RemotePipelineJob, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

    if id <= 0 {
        return Err(RemoteError::StatusFailed(
            "gitlab returned an invalid job id".into(),
        ));
    }

    let name = value["name"].as_str().unwrap_or("");
    let status = value["status"].as_str().unwrap_or("unknown");
    let stage = value["stage"].as_str().unwrap_or("");
    let web_url = value["web_url"].as_str().unwrap_or("");
    let started_at = value["started_at"].as_str().unwrap_or("");
    let finished_at = value["finished_at"].as_str().unwrap_or("");
    let duration = value["duration"].as_f64().unwrap_or(0.0);

    Ok(RemotePipelineJob {
        id,
        name: name.to_string(),
        status: status.to_string(),
        stage: stage.to_string(),
        web_url: web_url.to_string(),
        started_at: started_at.to_string(),
        finished_at: finished_at.to_string(),
        duration,
    })
}

/// Map a GitHub Actions `status`/`conclusion` pair onto the GitLab
/// vocabulary the UI already renders: completed runs report their
/// conclusion, in-flight states become `running`/`pending`.
fn normalize_github_status(status: &str, conclusion: &str) -> String {
    match status {
        "completed" => match conclusion {
            "success" => "success".into(),
            "failure" | "startup_failure" | "timed_out" | "stale" => "failed".into(),
            "cancelled" => "canceled".into(),
            "skipped" | "neutral" => "skipped".into(),
            "" => "unknown".into(),
            other => other.to_string(),
        },
        "in_progress" => "running".into(),
        "queued" | "requested" | "waiting" | "pending" => "pending".into(),
        "" => "unknown".into(),
        other => other.to_string(),
    }
}

fn parse_workflow_run(value: serde_json::Value) -> Result<RemotePipeline, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

    if id <= 0 {
        return Err(RemoteError::StatusFailed(
            "github returned an invalid workflow run id".into(),
        ));
    }

    let status = normalize_github_status(
        value["status"].as_str().unwrap_or(""),
        value["conclusion"].as_str().unwrap_or(""),
    );

    let name = value["name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| value["display_title"].as_str())
        .unwrap_or(&status)
        .to_string();

    Ok(RemotePipeline {
        id,
        status,
        name,
        web_url: value["html_url"].as_str().unwrap_or("").to_string(),
        ref_name: value["head_branch"].as_str().unwrap_or("").to_string(),
        created_at: value["created_at"].as_str().unwrap_or("").to_string(),
        updated_at: value["updated_at"].as_str().unwrap_or("").to_string(),
    })
}

fn parse_workflow_job(value: serde_json::Value) -> Result<RemotePipelineJob, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

    if id <= 0 {
        return Err(RemoteError::StatusFailed(
            "github returned an invalid job id".into(),
        ));
    }

    let status = normalize_github_status(
        value["status"].as_str().unwrap_or(""),
        value["conclusion"].as_str().unwrap_or(""),
    );

    let started_at = value["started_at"].as_str().unwrap_or("");
    let finished_at = value["completed_at"].as_str().unwrap_or("");
    let duration = if started_at.is_empty() || finished_at.is_empty() {
        0.0
    } else {
        (parse_timestamp(finished_at) - parse_timestamp(started_at)).num_milliseconds() as f64
            / 1000.0
    };

    Ok(RemotePipelineJob {
        id,
        name: value["name"].as_str().unwrap_or("").to_string(),
        status,
        stage: value["workflow_name"].as_str().unwrap_or("").to_string(),
        web_url: value["html_url"].as_str().unwrap_or("").to_string(),
        started_at: started_at.to_string(),
        finished_at: finished_at.to_string(),
        duration,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pipeline_falls_back_to_ref_name_and_unknown_status() {
        let value = serde_json::json!({
            "id": 7,
            "web_url": "https://gitlab.example.com/-/pipelines/7",
            "ref": "feature",
        });
        let p = parse_pipeline(value).unwrap();
        assert_eq!(p.id, 7);
        assert_eq!(p.status, "unknown");
        assert_eq!(p.name, "feature");
        assert_eq!(p.ref_name, "feature");
        assert_eq!(p.web_url, "https://gitlab.example.com/-/pipelines/7");
    }

    #[test]
    fn parse_pipeline_uses_detailed_status_group() {
        let value = serde_json::json!({
            "id": 1,
            "status": null,
            "detailed_status": { "group": "success" },
            "name": "build",
            "web_url": "https://example.com",
            "ref": "main",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-02T00:00:00Z",
        });
        let p = parse_pipeline(value).unwrap();
        assert_eq!(p.id, 1);
        assert_eq!(p.status, "success");
        assert_eq!(p.name, "build");
    }

    #[test]
    fn parse_pipeline_job_reads_all_fields() {
        let value = serde_json::json!({
            "id": 101,
            "name": "cargo test",
            "status": "running",
            "stage": "test",
            "web_url": "https://gitlab.example.com/-/jobs/101",
            "started_at": "2026-01-01T00:00:00Z",
            "finished_at": "2026-01-01T00:01:00Z",
            "duration": 60.5,
        });
        let job = parse_pipeline_job(value).unwrap();
        assert_eq!(job.id, 101);
        assert_eq!(job.name, "cargo test");
        assert_eq!(job.status, "running");
        assert_eq!(job.stage, "test");
        assert_eq!(job.web_url, "https://gitlab.example.com/-/jobs/101");
        assert_eq!(job.started_at, "2026-01-01T00:00:00Z");
        assert_eq!(job.finished_at, "2026-01-01T00:01:00Z");
        assert!((job.duration - 60.5).abs() < f64::EPSILON);
    }

    #[test]
    fn parse_pipeline_job_falls_back_to_defaults() {
        let value = serde_json::json!({
            "id": 42,
            "name": "build",
        });
        let job = parse_pipeline_job(value).unwrap();
        assert_eq!(job.id, 42);
        assert_eq!(job.name, "build");
        assert_eq!(job.status, "unknown");
        assert_eq!(job.stage, "");
        assert_eq!(job.duration, 0.0);
    }

    #[test]
    fn parse_pipeline_job_rejects_invalid_id() {
        let value = serde_json::json!({
            "id": 0,
            "name": "build",
        });
        let err = parse_pipeline_job(value).unwrap_err();
        assert!(matches!(err, RemoteError::StatusFailed(_)));
    }

    #[test]
    fn normalize_github_status_maps_to_gitlab_vocabulary() {
        assert_eq!(normalize_github_status("completed", "success"), "success");
        assert_eq!(normalize_github_status("completed", "failure"), "failed");
        assert_eq!(
            normalize_github_status("completed", "startup_failure"),
            "failed"
        );
        assert_eq!(normalize_github_status("completed", "timed_out"), "failed");
        assert_eq!(
            normalize_github_status("completed", "cancelled"),
            "canceled"
        );
        assert_eq!(normalize_github_status("completed", "skipped"), "skipped");
        assert_eq!(normalize_github_status("completed", "neutral"), "skipped");
        assert_eq!(normalize_github_status("in_progress", ""), "running");
        assert_eq!(normalize_github_status("queued", ""), "pending");
        assert_eq!(normalize_github_status("waiting", ""), "pending");
        assert_eq!(normalize_github_status("requested", ""), "pending");
        assert_eq!(normalize_github_status("", ""), "unknown");
        assert_eq!(
            normalize_github_status("completed", "action_required"),
            "action_required"
        );
    }

    #[test]
    fn parse_workflow_run_reads_github_fields() {
        let value = serde_json::json!({
            "id": 42,
            "status": "completed",
            "conclusion": "success",
            "name": "CI",
            "html_url": "https://github.com/o/r/actions/runs/42",
            "head_branch": "feature",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-02T00:00:00Z",
        });
        let p = parse_workflow_run(value).unwrap();
        assert_eq!(p.id, 42);
        assert_eq!(p.status, "success");
        assert_eq!(p.name, "CI");
        assert_eq!(p.ref_name, "feature");
        assert_eq!(p.web_url, "https://github.com/o/r/actions/runs/42");
    }

    #[test]
    fn parse_workflow_run_maps_running_and_rejects_bad_id() {
        let value = serde_json::json!({
            "id": 7,
            "status": "in_progress",
            "conclusion": null,
            "name": "build",
        });
        let p = parse_workflow_run(value).unwrap();
        assert_eq!(p.status, "running");

        let value = serde_json::json!({"id": 0});
        assert!(parse_workflow_run(value).is_err());
    }

    #[test]
    fn parse_workflow_job_reads_fields_and_computes_duration() {
        let value = serde_json::json!({
            "id": 101,
            "name": "cargo test",
            "status": "completed",
            "conclusion": "failure",
            "workflow_name": "CI",
            "html_url": "https://github.com/o/r/actions/runs/9/job/101",
            "started_at": "2026-01-01T00:00:00Z",
            "completed_at": "2026-01-01T00:01:00Z",
        });
        let job = parse_workflow_job(value).unwrap();
        assert_eq!(job.id, 101);
        assert_eq!(job.status, "failed");
        assert_eq!(job.stage, "CI");
        assert_eq!(job.finished_at, "2026-01-01T00:01:00Z");
        assert!((job.duration - 60.0).abs() < 0.001);
    }

    #[test]
    fn pipelines_sort_by_updated_at_descending() {
        let mut pipelines = [
            RemotePipeline {
                id: 1,
                status: "success".into(),
                name: "old".into(),
                web_url: "".into(),
                ref_name: "old".into(),
                created_at: "".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
            },
            RemotePipeline {
                id: 2,
                status: "failed".into(),
                name: "new".into(),
                web_url: "".into(),
                ref_name: "new".into(),
                created_at: "".into(),
                updated_at: "2026-01-03T00:00:00Z".into(),
            },
        ];
        pipelines.sort_by(|a, b| {
            let a_time = parse_timestamp(&a.updated_at);
            let b_time = parse_timestamp(&b.updated_at);
            b_time.cmp(&a_time)
        });
        assert_eq!(pipelines[0].ref_name, "new");
        assert_eq!(pipelines[1].ref_name, "old");
    }

    #[test]
    fn missing_timestamp_sorts_to_bottom() {
        let mut pipelines = [
            RemotePipeline {
                id: 1,
                status: "failed".into(),
                name: "missing".into(),
                web_url: "".into(),
                ref_name: "missing".into(),
                created_at: "".into(),
                updated_at: "".into(),
            },
            RemotePipeline {
                id: 2,
                status: "success".into(),
                name: "has".into(),
                web_url: "".into(),
                ref_name: "has".into(),
                created_at: "".into(),
                updated_at: "2026-01-02T00:00:00Z".into(),
            },
        ];
        pipelines.sort_by(|a, b| {
            let a_time = parse_timestamp(&a.updated_at);
            let b_time = parse_timestamp(&b.updated_at);
            b_time.cmp(&a_time)
        });
        assert_eq!(pipelines[0].ref_name, "has");
        assert_eq!(pipelines[1].ref_name, "missing");
    }
}
