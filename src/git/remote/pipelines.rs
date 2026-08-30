//! GitLab CI/CD pipeline fetching and parsing.

use chrono::{DateTime, Utc};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use super::{GitRemoteService, RemoteError};

/// A single CI/CD pipeline for a GitLab merge request.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabPipeline {
    pub id: i64,
    pub status: String,
    pub name: String,
    pub web_url: String,
    pub ref_name: String,
    pub created_at: String,
    pub updated_at: String,
}

/// A single job inside a GitLab CI/CD pipeline.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabPipelineJob {
    pub id: i64,
    pub name: String,
    pub status: String,
    pub stage: String,
    pub web_url: String,
    pub started_at: String,
    pub finished_at: String,
    pub duration: f64,
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
    ) -> Result<Vec<GitLabPipeline>, RemoteError> {
        if project_path.is_empty() {
            return Err(RemoteError::StatusFailed("project is required".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path =
            format!("projects/{encoded_project}/merge_requests/{iid}/pipelines?per_page=100");

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let pipelines: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid pipeline json: {e}"))
        })?;

        let mut pipelines: Vec<GitLabPipeline> = pipelines
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
    ) -> Result<Vec<GitLabPipelineJob>, RemoteError> {
        if project_path.is_empty() {
            return Err(RemoteError::StatusFailed("project is required".into()));
        }
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
}

fn parse_timestamp(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(DateTime::UNIX_EPOCH)
}

fn parse_pipeline(value: serde_json::Value) -> Result<GitLabPipeline, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

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

    Ok(GitLabPipeline {
        id,
        status: status.to_string(),
        name: name.to_string(),
        web_url: web_url.to_string(),
        ref_name: ref_name.to_string(),
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
    })
}

fn parse_pipeline_job(value: serde_json::Value) -> Result<GitLabPipelineJob, RemoteError> {
    let id = value["id"]
        .as_i64()
        .or_else(|| value["id"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);

    let name = value["name"].as_str().unwrap_or("");
    let status = value["status"].as_str().unwrap_or("unknown");
    let stage = value["stage"].as_str().unwrap_or("");
    let web_url = value["web_url"].as_str().unwrap_or("");
    let started_at = value["started_at"].as_str().unwrap_or("");
    let finished_at = value["finished_at"].as_str().unwrap_or("");
    let duration = value["duration"].as_f64().unwrap_or(0.0);

    Ok(GitLabPipelineJob {
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
            "name": "build",
        });
        let job = parse_pipeline_job(value).unwrap();
        assert_eq!(job.id, 0);
        assert_eq!(job.name, "build");
        assert_eq!(job.status, "unknown");
        assert_eq!(job.stage, "");
        assert_eq!(job.duration, 0.0);
    }

    #[test]
    fn pipelines_sort_by_updated_at_descending() {
        let mut pipelines = [
            GitLabPipeline {
                id: 1,
                status: "success".into(),
                name: "old".into(),
                web_url: "".into(),
                ref_name: "old".into(),
                created_at: "".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
            },
            GitLabPipeline {
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
            GitLabPipeline {
                id: 1,
                status: "failed".into(),
                name: "missing".into(),
                web_url: "".into(),
                ref_name: "missing".into(),
                created_at: "".into(),
                updated_at: "".into(),
            },
            GitLabPipeline {
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
