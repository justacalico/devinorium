//! GitLab remote URL and API path parsing.

use super::{GitRemoteService, RemoteError};

/// A GitLab project resolved from a git remote URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLabProjectRef {
    pub hostname: String,
    pub project_path: String,
}

/// Parse a git remote URL into a GitLab host and project path.
///
/// Handles the common forms:
///   git@gitlab.com:group/project.git
///   git@gitlab.example.com:group/subgroup/project.git
///   ssh://git@gitlab.com:22/group/project.git
///   https://gitlab.com/group/subgroup/project.git
///   https://user:token@gitlab.com/group/project.git
///
/// Returns `None` for URLs that are not parseable as a GitLab remote.
pub fn parse_gitlab_remote_url(url: &str) -> Option<GitLabProjectRef> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }

    // ssh://[user@]host[:port]/path
    if let Some(rest) = url.strip_prefix("ssh://") {
        let after_user = match rest.split_once('@') {
            Some((_, host_and_path)) => host_and_path,
            None => rest,
        };
        let (host_and_port, path) = after_user.split_once('/')?;
        let hostname = host_and_port
            .split_once(':')
            .map(|(h, _)| h)
            .unwrap_or(host_and_port);
        return GitRemoteService::build_ref(hostname, path);
    }

    // git@host:path  (scp-style)
    if let Some(rest) = url.strip_prefix("git@") {
        let (host, path) = rest.split_once(':')?;
        return GitRemoteService::build_ref(host, path);
    }

    // http(s)://[user:pass@]host/path
    if let Some(rest) = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://")) {
        let after_auth = match rest.split_once('@') {
            Some((_, host_and_path)) => host_and_path,
            None => rest,
        };
        let (host, path) = after_auth.split_once('/')?;
        // Strip a trailing query/fragment if present.
        let path = path.split(['?', '#']).next().unwrap_or(path);
        return GitRemoteService::build_ref(host, path);
    }

    None
}

impl GitRemoteService {
    pub(super) fn api_host(hostname: &str) -> &str {
        if hostname.is_empty() {
            "gitlab.com"
        } else {
            hostname
        }
    }

    pub(super) fn check_api_path(path: &str) -> Result<(), RemoteError> {
        if path.starts_with('/') {
            return Err(RemoteError::StatusFailed(
                "api path must not start with /".into(),
            ));
        }
        if !path.starts_with("projects/") {
            return Err(RemoteError::StatusFailed(
                "only project api paths are supported".into(),
            ));
        }
        if path.contains("..") || path.contains('\n') || path.contains('\r') {
            return Err(RemoteError::StatusFailed(
                "invalid characters in api path".into(),
            ));
        }
        Ok(())
    }

    pub(super) fn build_ref(hostname: &str, path: &str) -> Option<GitLabProjectRef> {
        let hostname = hostname.trim();
        let mut project_path = path.trim().trim_end_matches(".git").to_string();
        // A trailing slash is meaningless and breaks API paths.
        while project_path.ends_with('/') {
            project_path.pop();
        }
        if hostname.is_empty() || project_path.is_empty() {
            return None;
        }
        // Reject paths that look like filesystem traversal or contain whitespace
        // or control characters that could break the API path or shell handoff.
        if project_path.contains(' ')
            || project_path.contains("..")
            || project_path.contains('\0')
            || project_path.contains('\n')
            || project_path.contains('\r')
        {
            return None;
        }
        Some(GitLabProjectRef {
            hostname: hostname.to_string(),
            project_path,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_gitlab_remote_url_handles_scp_style() {
        let r = parse_gitlab_remote_url("git@gitlab.com:group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_gitlab_remote_url("git@gitlab.example.com:group/subgroup/project.git")
            .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/subgroup/project");
    }

    #[test]
    fn parse_gitlab_remote_url_handles_https() {
        let r = parse_gitlab_remote_url("https://gitlab.com/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_gitlab_remote_url(
            "https://user:token@gitlab.example.com/group/subgroup/project.git",
        )
        .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/subgroup/project");
    }

    #[test]
    fn parse_gitlab_remote_url_handles_ssh_scheme_with_port() {
        let r = parse_gitlab_remote_url("ssh://git@gitlab.com:22/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn parse_gitlab_remote_url_strips_trailing_dot_git_and_slash() {
        let r = parse_gitlab_remote_url("https://gitlab.com/group/project/").unwrap();
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn parse_gitlab_remote_url_rejects_garbage() {
        assert!(parse_gitlab_remote_url("").is_none());
        assert!(parse_gitlab_remote_url("not a url").is_none());
        assert!(parse_gitlab_remote_url("https://gitlab.com/").is_none());
        assert!(parse_gitlab_remote_url("https://gitlab.com/../project").is_none());
    }

    #[test]
    fn build_ref_rejects_invalid_paths() {
        assert!(GitRemoteService::build_ref("gitlab.com", "group /project").is_none());
        assert!(GitRemoteService::build_ref("gitlab.com", "group/../project").is_none());
        assert!(GitRemoteService::build_ref("gitlab.com", "").is_none());
        assert!(GitRemoteService::build_ref("", "group/project").is_none());
    }

    #[test]
    fn api_host_defaults_to_gitlab_com() {
        assert_eq!(GitRemoteService::api_host(""), "gitlab.com");
        assert_eq!(GitRemoteService::api_host("gitlab.example.com"), "gitlab.example.com");
    }

    #[test]
    fn check_api_path_allows_project_paths_and_rejects_invalid_input() {
        assert!(GitRemoteService::check_api_path("projects/group%2Fproject/merge_requests/1").is_ok());
        assert!(GitRemoteService::check_api_path("groups/some-group").is_err());
        assert!(GitRemoteService::check_api_path("/projects/foo").is_err());
        assert!(GitRemoteService::check_api_path("projects/foo\nbar").is_err());
        assert!(GitRemoteService::check_api_path("projects/foo/../bar").is_err());
    }
}
