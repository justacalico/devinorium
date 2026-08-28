//! GitLab CI/CD pipeline fetching and parsing.

use chrono::{DateTime, Utc};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use super::{GitRemoteService, RemoteError};

/// A single CI/CD pipeline for a GitLab merge request.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabPipeline {
    pub status: String,
    pub name: String,
    pub web_url: String,
    pub ref_name: String,
    pub created_at: String,
    pub updated_at: String,
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
        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/merge_requests/{iid}/pipelines?per_page=100"
        );

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
}

fn parse_timestamp(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or(DateTime::UNIX_EPOCH)
}

fn parse_pipeline(value: serde_json::Value) -> Result<GitLabPipeline, RemoteError> {
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
        status: status.to_string(),
        name: name.to_string(),
        web_url: web_url.to_string(),
        ref_name: ref_name.to_string(),
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
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
        assert_eq!(p.status, "success");
        assert_eq!(p.name, "build");
    }

    #[test]
    fn pipelines_sort_by_updated_at_descending() {
        let mut pipelines = vec![
            GitLabPipeline {
                status: "success".into(),
                name: "old".into(),
                web_url: "".into(),
                ref_name: "old".into(),
                created_at: "".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
            },
            GitLabPipeline {
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
        let mut pipelines = vec![
            GitLabPipeline {
                status: "failed".into(),
                name: "missing".into(),
                web_url: "".into(),
                ref_name: "missing".into(),
                created_at: "".into(),
                updated_at: "".into(),
            },
            GitLabPipeline {
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
