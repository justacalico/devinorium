//! GitLab remote URL and API path parsing.

use once_cell::sync::Lazy;
use percent_encoding::percent_decode;
use regex::Regex;

use super::{GitRemoteService, RemoteError};

/// A GitLab project resolved from a git remote URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLabProjectRef {
    pub hostname: String,
    pub project_path: String,
}

/// A merge request explicitly linked to a thread.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LinkedMergeRequest {
    pub hostname: String,
    pub project_path: String,
    pub iid: i64,
    pub web_url: String,
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

    // http(s)://[user:pass@]host[:port]/path
    if let Some(rest) = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
    {
        let after_auth = match rest.split_once('@') {
            Some((_, host_and_path)) => host_and_path,
            None => rest,
        };
        let (host_and_port, path) = after_auth.split_once('/')?;
        let hostname = host_and_port
            .split_once(':')
            .map(|(h, _)| h)
            .unwrap_or(host_and_port);
        // Strip a trailing query/fragment if present.
        let path = path.split(['?', '#']).next().unwrap_or(path);
        return GitRemoteService::build_ref(hostname, path);
    }

    None
}

/// Parse a GitLab merge request URL into a linked merge request reference.
///
/// Accepts any host so self-managed GitLab instances work. The path must
/// contain the `/-/merge_requests/` marker; everything before it is the project
/// path, and the following path segment is the integer IID.
///
///   https://gitlab.example.com/group/project/-/merge_requests/12
///   https://gitlab.example.com/group/project/-/merge_requests/12/diffs
pub fn parse_gitlab_merge_request_url(url: &str) -> Option<LinkedMergeRequest> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }

    // Scheme is case-insensitive in URLs; the rest of the path keeps its casing.
    let lower = url.to_lowercase();
    let (scheme, rest) = if lower.starts_with("https://") {
        ("https", &url[8..])
    } else if lower.starts_with("http://") {
        ("http", &url[7..])
    } else {
        return None;
    };

    // Strip optional user:pass@ authentication; the remainder is host + path.
    let host_and_path = match rest.split_once('@') {
        Some((_, after)) => after,
        None => rest,
    };

    let (host_port, raw_path) = host_and_path.split_once('/')?;
    let hostname = host_port
        .split_once(':')
        .map(|(h, _)| h)
        .unwrap_or(host_port);
    let hostname = hostname.trim();
    if hostname.is_empty() {
        return None;
    }

    // Strip trailing query/fragment for parsing so self-managed URLs are not tripped up.
    let path = raw_path.split(['?', '#']).next().unwrap_or(raw_path);
    if path.is_empty() {
        return None;
    }

    // Project paths are encoded with `/`; the marker is `/-/merge_requests/`.
    let mr_marker = "/-/merge_requests/";
    let marker_idx = path.find(mr_marker)?;
    let project_path = &path[..marker_idx];
    let after_marker = &path[marker_idx + mr_marker.len()..];

    let iid_str = after_marker.split('/').next().unwrap_or(after_marker);
    let iid = iid_str.parse::<i64>().ok().filter(|&n| n > 0)?;

    // Rebuild the URL without credentials, preserving port, path and query/fragment.
    let web_url = format!("{}://{}/{}", scheme, host_port.to_lowercase(), raw_path);

    GitRemoteService::build_ref(hostname, project_path).map(|r| LinkedMergeRequest {
        hostname: r.hostname,
        project_path: r.project_path,
        iid,
        web_url,
    })
}

/// Pattern for GitLab merge request URLs embedded in arbitrary text. Matches
/// the same character set the Flutter client uses so assistant replies and
/// pasted messages are discovered consistently.
static MR_URL_RE: Lazy<Regex> = Lazy::new(|| {
    regex::RegexBuilder::new(r#"https?://[^\s<>"`{}|\\^`\[\]]+?/-/merge_requests/\d+"#)
        .case_insensitive(true)
        .build()
        .unwrap()
});

/// Extract and parse the first valid GitLab merge request URL found in text.
pub fn first_gitlab_merge_request_url(content: &str) -> Option<LinkedMergeRequest> {
    MR_URL_RE
        .find_iter(content)
        .find_map(|m| parse_gitlab_merge_request_url(m.as_str()))
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
        let hostname = hostname.trim().to_lowercase();
        if hostname.is_empty() {
            return None;
        }
        let mut project_path = path.trim().trim_end_matches(".git").to_lowercase();
        // A leading or trailing slash is meaningless and breaks API paths.
        while project_path.starts_with('/') {
            project_path.remove(0);
        }
        while project_path.ends_with('/') {
            project_path.pop();
        }
        // Percent-decode so callers can paste already-encoded URLs; this also
        // turns encoded traversal ("%2E%2E") into plain ".." before we validate.
        project_path = percent_decode(project_path.as_bytes())
            .decode_utf8_lossy()
            .into_owned();
        if project_path.is_empty() {
            return None;
        }
        // Reject paths that look like filesystem traversal, contain whitespace,
        // control characters, or characters that would break an API path.
        if project_path.contains(' ')
            || project_path.contains("..")
            || project_path.contains(':')
            || project_path.contains("//")
            || project_path.contains('\0')
            || project_path.contains('\n')
            || project_path.contains('\r')
        {
            return None;
        }
        Some(GitLabProjectRef {
            hostname,
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

        let r =
            parse_gitlab_remote_url("git@gitlab.example.com:group/subgroup/project.git").unwrap();
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

        let r =
            parse_gitlab_remote_url("https://gitlab.example.com:8443/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_gitlab_remote_url("https://gitlab.com//group/project.git").unwrap();
        assert_eq!(r.project_path, "group/project");
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
        assert!(GitRemoteService::build_ref("gitlab.com", "group/project:foo").is_none());
        assert!(GitRemoteService::build_ref("gitlab.com", "group//project").is_none());
        assert!(GitRemoteService::build_ref("gitlab.com", "group%2F..%2Fproject").is_none());
    }

    #[test]
    fn build_ref_lowercases_hostname_and_decodes_project_path() {
        let r = GitRemoteService::build_ref("GITLAB.COM", "group%2Fproject").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn api_host_defaults_to_gitlab_com() {
        assert_eq!(GitRemoteService::api_host(""), "gitlab.com");
        assert_eq!(
            GitRemoteService::api_host("gitlab.example.com"),
            "gitlab.example.com"
        );
    }

    #[test]
    fn check_api_path_allows_project_paths_and_rejects_invalid_input() {
        assert!(
            GitRemoteService::check_api_path("projects/group%2Fproject/merge_requests/1").is_ok()
        );
        assert!(GitRemoteService::check_api_path("groups/some-group").is_err());
        assert!(GitRemoteService::check_api_path("/projects/foo").is_err());
        assert!(GitRemoteService::check_api_path("projects/foo\nbar").is_err());
        assert!(GitRemoteService::check_api_path("projects/foo/../bar").is_err());
    }

    #[test]
    fn parse_gitlab_merge_request_url_extracts_host_path_and_iid() {
        let r = parse_gitlab_merge_request_url(
            "https://gitlab.example.com/group/project/-/merge_requests/12",
        )
        .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");
        assert_eq!(r.iid, 12);
        assert_eq!(
            r.web_url,
            "https://gitlab.example.com/group/project/-/merge_requests/12"
        );
    }

    #[test]
    fn parse_gitlab_merge_request_url_accepts_self_managed_hosts() {
        let r =
            parse_gitlab_merge_request_url("https://git.example.com/a/b/-/merge_requests/7?foo=1")
                .unwrap();
        assert_eq!(r.hostname, "git.example.com");
        assert_eq!(r.project_path, "a/b");
        assert_eq!(r.iid, 7);
    }

    #[test]
    fn parse_gitlab_merge_request_url_ignores_trailing_path_segments() {
        let r = parse_gitlab_merge_request_url(
            "https://gitlab.com/group/project/-/merge_requests/42/diffs",
        )
        .unwrap();
        assert_eq!(r.project_path, "group/project");
        assert_eq!(r.iid, 42);
    }

    #[test]
    fn parse_gitlab_merge_request_url_rejects_invalid_urls() {
        assert!(parse_gitlab_merge_request_url("").is_none());
        assert!(parse_gitlab_merge_request_url("not a url").is_none());
        assert!(parse_gitlab_merge_request_url("https://gitlab.com").is_none());
        assert!(parse_gitlab_merge_request_url("https://gitlab.com/group/project").is_none());
        assert!(parse_gitlab_merge_request_url(
            "https://gitlab.com/group/project/merge_requests/12"
        )
        .is_none());
        assert!(parse_gitlab_merge_request_url(
            "https://gitlab.com/group/project/-/merge_requests/abc"
        )
        .is_none());
        assert!(parse_gitlab_merge_request_url(
            "https://evil.com/https://gitlab.com/group/project/-/merge_requests/12"
        )
        .is_none());
    }

    #[test]
    fn parse_gitlab_merge_request_url_is_case_and_percent_agnostic() {
        let r = parse_gitlab_merge_request_url(
            "https://GITLAB.EXAMPLE.COM/group%2Fproject/-/merge_requests/12",
        )
        .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");
        assert_eq!(r.iid, 12);
    }

    #[test]
    fn parse_gitlab_merge_request_url_strips_credentials_and_preserves_port() {
        let r = parse_gitlab_merge_request_url(
            "https://user:pass@gitlab.example.com:8443/group%2Fproject/-/merge_requests/12/diffs?foo=1",
        )
        .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");
        assert_eq!(r.iid, 12);
        assert!(!r.web_url.contains("user"));
        assert!(!r.web_url.contains("pass"));
        assert!(r.web_url.starts_with("https://gitlab.example.com:8443/"));
        assert!(r.web_url.ends_with("/diffs?foo=1"));
    }

    #[test]
    fn parse_gitlab_merge_request_url_is_case_insensitive_for_scheme() {
        let r = parse_gitlab_merge_request_url(
            "HTTPS://gitlab.example.com/group/project/-/merge_requests/5",
        )
        .unwrap();
        assert_eq!(r.iid, 5);
        assert_eq!(
            r.web_url,
            "https://gitlab.example.com/group/project/-/merge_requests/5"
        );
    }

    #[test]
    fn first_gitlab_merge_request_url_extracts_first_valid_url() {
        let text = "Done. https://gitlab.example.com/group/project/-/merge_requests/5";
        let r = first_gitlab_merge_request_url(text).unwrap();
        assert_eq!(r.iid, 5);
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn first_gitlab_merge_request_url_prefers_first_matching_remote() {
        let text = "See https://evil.com/thing and \
                    https://gitlab.com/group/project/-/merge_requests/42";
        let r = first_gitlab_merge_request_url(text).unwrap();
        assert_eq!(r.iid, 42);
    }

    #[test]
    fn first_gitlab_merge_request_url_ignores_invalid_urls() {
        assert!(first_gitlab_merge_request_url("no urls here").is_none());
        assert!(first_gitlab_merge_request_url(
            "https://gitlab.com/group/project/merge_requests/5"
        )
        .is_none());
    }

    #[test]
    fn first_gitlab_merge_request_url_is_case_insensitive_for_scheme() {
        let text = "Done: HTTPS://GITLAB.EXAMPLE.COM/Group/Project/-/merge_requests/7";
        let r = first_gitlab_merge_request_url(text).unwrap();
        assert_eq!(r.iid, 7);
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");
    }
}
