//! GitLab issue listing.

use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use super::{GitRemoteService, RemoteError};

/// A lightweight issue summary, used to surface a repo's open issues in the
/// sidebar git panel without loading the full note payload.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GitLabIssueSummary {
    pub iid: i64,
    pub title: String,
    pub state: String,
    pub web_url: String,
    pub labels: Vec<String>,
}

impl GitRemoteService {
    /// List a project's open issues, most recently updated first.
    pub async fn gitlab_issues(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        per_page: usize,
    ) -> Result<Vec<GitLabIssueSummary>, RemoteError> {
        if project_path.is_empty() {
            return Err(RemoteError::StatusFailed("project is required".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/issues\
             ?state=opened&order_by=updated_at&per_page={per_page}"
        );

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid issue json: {e}"))
        })?;

        Ok(list.into_iter().map(parse_issue_summary).collect())
    }
}

pub(super) fn parse_issue_summary(value: serde_json::Value) -> GitLabIssueSummary {
    let iid = value["iid"]
        .as_i64()
        .or_else(|| value["iid"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);
    let labels = value["labels"]
        .as_array()
        .map(|labels| {
            labels
                .iter()
                .filter_map(|l| l.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    GitLabIssueSummary {
        iid,
        title: value["title"].as_str().unwrap_or("").to_string(),
        state: value["state"].as_str().unwrap_or("").to_string(),
        web_url: value["web_url"].as_str().unwrap_or("").to_string(),
        labels,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_issue_summary_reads_all_fields() {
        let value = serde_json::json!({
            "iid": 42,
            "title": "Fix the thing",
            "state": "opened",
            "web_url": "https://gitlab.example.com/group/project/-/issues/42",
            "labels": ["bug", "backend"],
        });
        let issue = parse_issue_summary(value);
        assert_eq!(issue.iid, 42);
        assert_eq!(issue.title, "Fix the thing");
        assert_eq!(issue.state, "opened");
        assert_eq!(
            issue.web_url,
            "https://gitlab.example.com/group/project/-/issues/42"
        );
        assert_eq!(issue.labels, vec!["bug", "backend"]);
    }

    #[test]
    fn parse_issue_summary_tolerates_missing_labels_and_string_iid() {
        let value = serde_json::json!({
            "iid": "7",
            "title": "Sparse",
            "state": "opened",
        });
        let issue = parse_issue_summary(value);
        assert_eq!(issue.iid, 7);
        assert!(issue.labels.is_empty());
        assert_eq!(issue.web_url, "");
    }
}
