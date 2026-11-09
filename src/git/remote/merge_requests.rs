//! Merge request and pull request lookups and write actions.

use std::time::Duration;

use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

use super::{GitHost, GitRemoteService, RemoteError};

/// A write action that can be applied to a merge request or pull request.
///
/// The set is deliberately closed so the frontend cannot ask the backend to
/// perform arbitrary mutations through the CLI proxy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeRequestAction {
    Close,
    Reopen,
    Merge,
    MergeWhenPipelineSucceeds,
    CancelAutoMerge,
}

/// A lightweight merge/pull request summary, used to surface the open MR
/// linked to a thread's branch without loading the full diff/comment payload.
#[derive(Debug, Clone, serde::Serialize)]
pub struct MergeRequestSummary {
    pub provider: GitHost,
    pub iid: i64,
    pub title: String,
    pub state: String,
    pub source_branch: String,
    pub target_branch: String,
    pub web_url: String,
    pub draft: bool,
}

impl GitRemoteService {
    /// Load a single merge request by IID.
    ///
    /// Returns the full GitLab JSON for the merge request, which is then
    /// converted into a lightweight summary by the caller.
    pub async fn gitlab_merge_request(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
    ) -> Result<MergeRequestSummary, RemoteError> {
        if project_path.is_empty() || iid <= 0 {
            return Err(RemoteError::StatusFailed(
                "merge request reference is invalid".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!("projects/{encoded_project}/merge_requests/{iid}");
        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid merge request json: {e}"))
        })?;
        Ok(parse_merge_request_summary(value))
    }

    /// Apply a state change to a merge request and return the updated JSON.
    ///
    /// `Merge` can take a while for GitLab to actually complete (large repos,
    /// post-merge hooks, etc.). If the first call times out we poll the MR
    /// state so the user sees the final result instead of a raw timeout.
    pub async fn gitlab_merge_request_action(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        iid: i64,
        action: MergeRequestAction,
    ) -> Result<serde_json::Value, RemoteError> {
        if project_path.is_empty() || iid <= 0 {
            return Err(RemoteError::StatusFailed(
                "merge request reference is invalid".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let base = format!("projects/{encoded_project}/merge_requests/{iid}");
        let (method, path, fields) = merge_request_action_request(&encoded_project, iid, action);

        let timeout = match action {
            MergeRequestAction::Merge => self.merge_timeout,
            _ => Duration::from_secs(30),
        };

        match self
            .gitlab_api_write(user_id, hostname, method, &path, &fields, timeout)
            .await
        {
            Ok(output) => Self::parse_merge_request_json(&output),
            Err(RemoteError::Timeout) if action == MergeRequestAction::Merge => {
                self.poll_merge_request_state(user_id, hostname, &base)
                    .await
            }
            Err(e) => Err(e),
        }
    }

    /// List a project's open merge requests, most recently updated first.
    pub async fn gitlab_merge_requests(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        per_page: usize,
    ) -> Result<Vec<MergeRequestSummary>, RemoteError> {
        if project_path.is_empty() {
            return Err(RemoteError::StatusFailed("project is required".into()));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/merge_requests\
             ?state=opened&order_by=updated_at&per_page={per_page}"
        );

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid merge request json: {e}"))
        })?;

        Ok(list.into_iter().map(parse_merge_request_summary).collect())
    }

    /// Find the open merge request whose source branch matches [branch] in the
    /// given GitLab project. Returns the first match, or `None` if there is no
    /// open merge request for that branch.
    pub async fn gitlab_merge_request_for_branch(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        branch: &str,
    ) -> Result<Option<MergeRequestSummary>, RemoteError> {
        if project_path.is_empty() || branch.is_empty() {
            return Err(RemoteError::StatusFailed(
                "project and branch are required".into(),
            ));
        }

        let encoded_project = utf8_percent_encode(project_path, NON_ALPHANUMERIC).to_string();
        let encoded_branch = utf8_percent_encode(branch, NON_ALPHANUMERIC).to_string();
        let path = format!(
            "projects/{encoded_project}/merge_requests\
             ?source_branch={encoded_branch}&state=opened&per_page=1"
        );

        let output = self.gitlab_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("gitlab returned invalid merge request json: {e}"))
        })?;

        Ok(list.into_iter().next().map(parse_merge_request_summary))
    }

    /// Load a single pull request by number.
    pub async fn github_pull_request(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        number: i64,
    ) -> Result<MergeRequestSummary, RemoteError> {
        if project_path.is_empty() || number <= 0 {
            return Err(RemoteError::StatusFailed(
                "pull request reference is invalid".into(),
            ));
        }

        let repo = Self::github_repo_path(project_path)?;
        let output = self
            .github_api(user_id, hostname, &format!("{repo}/pulls/{number}"))
            .await?;
        let value: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid pull request json: {e}"))
        })?;
        Ok(parse_pull_request_summary(value))
    }

    /// Apply a state change to a pull request and return the updated JSON.
    ///
    /// `Merge` can take a while for GitHub to actually complete. If the first
    /// call times out we poll the PR state so the user sees the final result
    /// instead of a raw timeout.
    pub async fn github_pull_request_action(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        number: i64,
        action: MergeRequestAction,
    ) -> Result<serde_json::Value, RemoteError> {
        if project_path.is_empty() || number <= 0 {
            return Err(RemoteError::StatusFailed(
                "pull request reference is invalid".into(),
            ));
        }

        let repo = Self::github_repo_path(project_path)?;
        let base = format!("{repo}/pulls/{number}");

        match action {
            MergeRequestAction::MergeWhenPipelineSucceeds => {
                self.github_auto_merge(user_id, hostname, &repo, number, true)
                    .await
            }
            MergeRequestAction::CancelAutoMerge => {
                self.github_auto_merge(user_id, hostname, &repo, number, false)
                    .await
            }
            _ => {
                let (method, path, fields) = match action {
                    MergeRequestAction::Close => ("PATCH", base.clone(), vec![("state", "closed")]),
                    MergeRequestAction::Reopen => ("PATCH", base.clone(), vec![("state", "open")]),
                    MergeRequestAction::Merge => ("PUT", format!("{base}/merge"), Vec::new()),
                    MergeRequestAction::MergeWhenPipelineSucceeds
                    | MergeRequestAction::CancelAutoMerge => unreachable!(),
                };

                let timeout = match action {
                    MergeRequestAction::Merge => self.merge_timeout,
                    _ => Duration::from_secs(30),
                };

                match self
                    .github_api_write(user_id, hostname, method, &path, &fields, timeout)
                    .await
                {
                    Ok(output) => Self::parse_merge_request_json(&output),
                    Err(RemoteError::Timeout) if action == MergeRequestAction::Merge => {
                        self.poll_pull_request_state(user_id, hostname, &base).await
                    }
                    Err(e) => Err(e),
                }
            }
        }
    }

    /// List a repository's open pull requests, most recently updated first.
    pub async fn github_pull_requests(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        per_page: usize,
    ) -> Result<Vec<MergeRequestSummary>, RemoteError> {
        if project_path.is_empty() {
            return Err(RemoteError::StatusFailed("project is required".into()));
        }

        let repo = Self::github_repo_path(project_path)?;
        let path =
            format!("{repo}/pulls?state=open&sort=updated&direction=desc&per_page={per_page}");

        let output = self.github_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid pull request json: {e}"))
        })?;

        Ok(list.into_iter().map(parse_pull_request_summary).collect())
    }

    /// Find the open pull request whose head branch matches [branch] in the
    /// given repository. Returns the first match, or `None` if there is no
    /// open pull request for that branch.
    pub async fn github_pull_request_for_branch(
        &self,
        user_id: i64,
        hostname: &str,
        project_path: &str,
        branch: &str,
    ) -> Result<Option<MergeRequestSummary>, RemoteError> {
        if project_path.is_empty() || branch.is_empty() {
            return Err(RemoteError::StatusFailed(
                "project and branch are required".into(),
            ));
        }

        let repo = Self::github_repo_path(project_path)?;
        let owner = project_path.split('/').next().unwrap_or("");
        let head = utf8_percent_encode(&format!("{owner}:{branch}"), NON_ALPHANUMERIC).to_string();
        let path = format!("{repo}/pulls?head={head}&state=open&per_page=1");

        let output = self.github_api(user_id, hostname, &path).await?;
        let list: Vec<serde_json::Value> = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid pull request json: {e}"))
        })?;

        Ok(list.into_iter().next().map(parse_pull_request_summary))
    }

    /// Enable or disable auto-merge on a pull request through the GraphQL
    /// API, the only place GitHub exposes it.
    async fn github_auto_merge(
        &self,
        user_id: i64,
        hostname: &str,
        repo: &str,
        number: i64,
        enable: bool,
    ) -> Result<serde_json::Value, RemoteError> {
        let output = self
            .github_api(user_id, hostname, &format!("{repo}/pulls/{number}"))
            .await?;
        let pr: serde_json::Value = serde_json::from_str(&output).map_err(|e| {
            RemoteError::StatusFailed(format!("github returned invalid pull request json: {e}"))
        })?;
        let node_id = pr["node_id"].as_str().ok_or_else(|| {
            RemoteError::StatusFailed("github did not return a pull request id".into())
        })?;

        let mutation = if enable {
            "mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:MERGE}){pullRequest{number}}}"
        } else {
            "mutation($id:ID!){disablePullRequestAutoMerge(input:{pullRequestId:$id}){pullRequest{number}}}"
        };
        let output = self
            .github_api_write(
                user_id,
                hostname,
                "POST",
                "graphql",
                &[("query", mutation), ("id", node_id)],
                Duration::from_secs(30),
            )
            .await?;

        let value = Self::parse_merge_request_json(&output)?;
        if let Some(errors) = value["errors"].as_array().filter(|e| !e.is_empty()) {
            let msg = errors
                .iter()
                .filter_map(|e| e["message"].as_str())
                .collect::<Vec<_>>()
                .join("; ");
            return Err(RemoteError::StatusFailed(if msg.is_empty() {
                "github graphql request failed".into()
            } else {
                msg
            }));
        }
        Ok(value)
    }

    pub(super) async fn poll_merge_request_state(
        &self,
        user_id: i64,
        hostname: &str,
        mr_path: &str,
    ) -> Result<serde_json::Value, RemoteError> {
        let max_attempts = 60; // up to 60 * 3s = 3 minutes with defaults

        for attempt in 0..max_attempts {
            tokio::time::sleep(self.poll_interval).await;
            match self.gitlab_api(user_id, hostname, mr_path).await {
                Ok(output) => {
                    let value = Self::parse_merge_request_json(&output)?;
                    if let Some(state) = value["state"].as_str() {
                        if state == "merged" || state == "closed" {
                            return Ok(value);
                        }
                    }
                    // Still open or in an intermediate state; keep polling.
                }
                Err(RemoteError::Timeout) if attempt == max_attempts - 1 => {
                    return Err(RemoteError::StatusFailed(
                        "GitLab did not finish the merge in time".into(),
                    ));
                }
                Err(RemoteError::Timeout) => continue,
                Err(e) => return Err(e),
            }
        }

        Err(RemoteError::StatusFailed(
            "GitLab did not finish the merge in time".into(),
        ))
    }

    /// Poll a pull request until GitHub reports it merged or closed, used
    /// after a timed-out merge request so the caller still sees the result.
    async fn poll_pull_request_state(
        &self,
        user_id: i64,
        hostname: &str,
        pr_path: &str,
    ) -> Result<serde_json::Value, RemoteError> {
        let max_attempts = 60; // up to 60 * 3s = 3 minutes with defaults

        for attempt in 0..max_attempts {
            tokio::time::sleep(self.poll_interval).await;
            match self.github_api(user_id, hostname, pr_path).await {
                Ok(output) => {
                    let value = Self::parse_merge_request_json(&output)?;
                    let merged = value["merged"].as_bool().unwrap_or(false)
                        || value["merged_at"].is_string();
                    if merged || value["state"].as_str() == Some("closed") {
                        return Ok(value);
                    }
                }
                Err(RemoteError::Timeout) if attempt == max_attempts - 1 => {
                    return Err(RemoteError::StatusFailed(
                        "GitHub did not finish the merge in time".into(),
                    ));
                }
                Err(RemoteError::Timeout) => continue,
                Err(e) => return Err(e),
            }
        }

        Err(RemoteError::StatusFailed(
            "GitHub did not finish the merge in time".into(),
        ))
    }

    pub(super) fn parse_merge_request_json(output: &str) -> Result<serde_json::Value, RemoteError> {
        serde_json::from_str(output)
            .map_err(|e| RemoteError::StatusFailed(format!("git host returned invalid json: {e}")))
    }
}

pub(super) fn merge_request_action_request(
    encoded_project: &str,
    iid: i64,
    action: MergeRequestAction,
) -> (&'static str, String, Vec<(&'static str, &'static str)>) {
    let base = format!("projects/{encoded_project}/merge_requests/{iid}");
    match action {
        MergeRequestAction::Close => ("PUT", base, vec![("state_event", "close")]),
        MergeRequestAction::Reopen => ("PUT", base, vec![("state_event", "reopen")]),
        MergeRequestAction::Merge => ("PUT", format!("{base}/merge"), Vec::new()),
        MergeRequestAction::MergeWhenPipelineSucceeds => (
            "PUT",
            format!("{base}/merge"),
            vec![("merge_when_pipeline_succeeds", "true")],
        ),
        MergeRequestAction::CancelAutoMerge => (
            "POST",
            format!("{base}/cancel_merge_when_pipeline_succeeds"),
            Vec::new(),
        ),
    }
}

pub(super) fn parse_merge_request_summary(value: serde_json::Value) -> MergeRequestSummary {
    let iid = value["iid"]
        .as_i64()
        .or_else(|| value["iid"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);
    MergeRequestSummary {
        provider: GitHost::GitLab,
        iid,
        title: value["title"].as_str().unwrap_or("").to_string(),
        state: value["state"].as_str().unwrap_or("").to_string(),
        source_branch: value["source_branch"].as_str().unwrap_or("").to_string(),
        target_branch: value["target_branch"].as_str().unwrap_or("").to_string(),
        web_url: value["web_url"].as_str().unwrap_or("").to_string(),
        draft: value["draft"].as_bool().unwrap_or(false),
    }
}

/// Convert a GitHub pull request JSON object into the shared summary shape.
///
/// GitHub reports `state` as only `open`/`closed`; a closed PR that was
/// merged is surfaced as `merged` so the UI shows the same states GitLab
/// does.
pub(super) fn parse_pull_request_summary(value: serde_json::Value) -> MergeRequestSummary {
    let iid = value["number"]
        .as_i64()
        .or_else(|| value["number"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0);
    let merged = value["merged"].as_bool().unwrap_or(false) || value["merged_at"].is_string();
    let state = if merged {
        "merged".to_string()
    } else {
        value["state"].as_str().unwrap_or("").to_string()
    };
    MergeRequestSummary {
        provider: GitHost::GitHub,
        iid,
        title: value["title"].as_str().unwrap_or("").to_string(),
        state,
        source_branch: value["head"]["ref"].as_str().unwrap_or("").to_string(),
        target_branch: value["base"]["ref"].as_str().unwrap_or("").to_string(),
        web_url: value["html_url"].as_str().unwrap_or("").to_string(),
        draft: value["draft"].as_bool().unwrap_or(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_request_action_request_for_each_action() {
        let project = "group%2Fproject";
        assert_eq!(
            merge_request_action_request(project, 7, MergeRequestAction::Close),
            (
                "PUT",
                "projects/group%2Fproject/merge_requests/7".to_string(),
                vec![("state_event", "close")]
            )
        );
        assert_eq!(
            merge_request_action_request(project, 7, MergeRequestAction::Reopen),
            (
                "PUT",
                "projects/group%2Fproject/merge_requests/7".to_string(),
                vec![("state_event", "reopen")]
            )
        );
        assert_eq!(
            merge_request_action_request(project, 7, MergeRequestAction::Merge),
            (
                "PUT",
                "projects/group%2Fproject/merge_requests/7/merge".to_string(),
                Vec::<(&str, &str)>::new()
            )
        );
        assert_eq!(
            merge_request_action_request(project, 7, MergeRequestAction::MergeWhenPipelineSucceeds),
            (
                "PUT",
                "projects/group%2Fproject/merge_requests/7/merge".to_string(),
                vec![("merge_when_pipeline_succeeds", "true")]
            )
        );
        assert_eq!(
            merge_request_action_request(project, 7, MergeRequestAction::CancelAutoMerge),
            (
                "POST",
                "projects/group%2Fproject/merge_requests/7/cancel_merge_when_pipeline_succeeds"
                    .to_string(),
                Vec::<(&str, &str)>::new()
            )
        );
    }

    #[test]
    fn parse_merge_request_summary_reads_all_fields() {
        let value = serde_json::json!({
            "iid": 12,
            "title": "Add feature",
            "state": "opened",
            "source_branch": "feature/branch",
            "target_branch": "main",
            "web_url": "https://gitlab.example.com/group/project/-/merge_requests/12",
            "draft": false,
        });
        let mr = parse_merge_request_summary(value);
        assert_eq!(mr.provider, GitHost::GitLab);
        assert_eq!(mr.iid, 12);
        assert_eq!(mr.title, "Add feature");
        assert_eq!(mr.state, "opened");
        assert_eq!(mr.source_branch, "feature/branch");
        assert_eq!(mr.target_branch, "main");
        assert_eq!(
            mr.web_url,
            "https://gitlab.example.com/group/project/-/merge_requests/12"
        );
        assert!(!mr.draft);
    }

    #[test]
    fn parse_pull_request_summary_reads_github_fields() {
        let value = serde_json::json!({
            "number": 34,
            "title": "Add feature",
            "state": "open",
            "head": {"ref": "feature/branch"},
            "base": {"ref": "main"},
            "html_url": "https://github.com/owner/repo/pull/34",
            "draft": true,
        });
        let pr = parse_pull_request_summary(value);
        assert_eq!(pr.provider, GitHost::GitHub);
        assert_eq!(pr.iid, 34);
        assert_eq!(pr.title, "Add feature");
        assert_eq!(pr.state, "open");
        assert_eq!(pr.source_branch, "feature/branch");
        assert_eq!(pr.target_branch, "main");
        assert_eq!(pr.web_url, "https://github.com/owner/repo/pull/34");
        assert!(pr.draft);
    }

    #[test]
    fn parse_pull_request_summary_reports_merged_state() {
        let value = serde_json::json!({
            "number": 7,
            "state": "closed",
            "merged": true,
            "head": {"ref": "f"},
            "base": {"ref": "main"},
            "html_url": "https://github.com/o/r/pull/7",
        });
        let pr = parse_pull_request_summary(value);
        assert_eq!(pr.state, "merged");

        let value = serde_json::json!({
            "number": 8,
            "state": "closed",
            "merged_at": "2026-01-01T00:00:00Z",
            "head": {"ref": "f"},
            "base": {"ref": "main"},
        });
        assert_eq!(parse_pull_request_summary(value).state, "merged");

        let value = serde_json::json!({
            "number": 9,
            "state": "closed",
            "merged": false,
            "head": {"ref": "f"},
            "base": {"ref": "main"},
        });
        assert_eq!(parse_pull_request_summary(value).state, "closed");
    }

    #[test]
    fn parse_merge_request_json_rejects_invalid_json() {
        assert!(GitRemoteService::parse_merge_request_json("not json").is_err());
    }

    #[test]
    fn parse_merge_request_json_accepts_valid_json() {
        let value = GitRemoteService::parse_merge_request_json(r#"{"state":"merged"}"#).unwrap();
        assert_eq!(value["state"], "merged");
    }
}
