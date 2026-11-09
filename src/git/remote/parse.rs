//! Git remote URL and API path parsing for GitLab and GitHub.

use once_cell::sync::Lazy;
use percent_encoding::{percent_decode, utf8_percent_encode, NON_ALPHANUMERIC};
use regex::Regex;

use super::{GitHost, GitRemoteService, RemoteError};

/// A project on a git host resolved from a git remote URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteProjectRef {
    pub hostname: String,
    pub project_path: String,
}

/// A merge/pull request explicitly linked to a thread.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LinkedMergeRequest {
    #[serde(default = "default_linked_mr_provider")]
    pub provider: GitHost,
    pub hostname: String,
    pub project_path: String,
    pub iid: i64,
    pub web_url: String,
}

fn default_linked_mr_provider() -> GitHost {
    GitHost::GitLab
}

/// Parse a git remote URL into a host and project path.
///
/// Handles the common forms:
///   git@gitlab.com:group/project.git
///   git@github.com:owner/repo.git
///   ssh://git@gitlab.com:22/group/project.git
///   https://gitlab.com/group/subgroup/project.git
///   https://user:token@gitlab.com/group/project.git
///
/// The result is provider-agnostic — use [`detect_remote`] to also learn
/// which git host the URL belongs to. Returns `None` for URLs that are not
/// parseable as a git remote.
pub fn parse_git_remote_url(url: &str) -> Option<RemoteProjectRef> {
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

/// Whether a remote hostname belongs to GitHub.
///
/// Covers github.com and GitHub Enterprise Cloud (`*.ghe.com` and
/// `*.ghe.localhost` for Enterprise Cloud with data residency). Self-hosted
/// GitHub Enterprise domains cannot be distinguished from self-managed
/// GitLab by name alone and resolve as GitLab.
pub fn is_github_hostname(hostname: &str) -> bool {
    let h = hostname.trim().to_lowercase();
    h == "github.com" || h.ends_with(".ghe.com") || h.ends_with(".ghe.localhost")
}

/// Detect the git host a remote URL belongs to.
///
/// Returns the provider and the parsed project ref, or `None` when the URL
/// is not a parseable git remote at all.
pub fn detect_remote(url: &str) -> Option<(GitHost, RemoteProjectRef)> {
    let r = parse_git_remote_url(url)?;
    Some((GitHost::for_hostname(&r.hostname), r))
}

/// Parse a git remote URL only when it points at GitHub.
pub fn parse_github_remote_url(url: &str) -> Option<RemoteProjectRef> {
    let r = parse_git_remote_url(url)?;
    is_github_hostname(&r.hostname).then_some(r)
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
    let (scheme, host_port, hostname, raw_path) = split_web_url(url)?;
    let path = raw_path.split(['?', '#']).next().unwrap_or(&raw_path);
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

    GitRemoteService::build_ref(&hostname, project_path).map(|r| LinkedMergeRequest {
        provider: GitHost::GitLab,
        hostname: r.hostname,
        project_path: r.project_path,
        iid,
        web_url,
    })
}

/// Parse a GitHub pull request URL into a linked merge request reference.
///
/// Any host is accepted so self-hosted GitHub Enterprise domains work; the
/// `/pull/` path marker is GitHub-specific and callers still verify the
/// resolved provider against the project's remote. The two segments before
/// the marker are the owner and repository, and the following path segment
/// is the pull request number.
///
///   https://github.com/owner/repo/pull/12
///   https://github.com/owner/repo/pull/12/files
pub fn parse_github_pull_request_url(url: &str) -> Option<LinkedMergeRequest> {
    let (scheme, host_port, hostname, raw_path) = split_web_url(url)?;

    let path = raw_path.split(['?', '#']).next().unwrap_or(&raw_path);
    if path.is_empty() {
        return None;
    }

    // The last `/pull/` wins so an owner or repo literally named `pull`
    // (github.com/pull/pull/pull/5) still resolves correctly.
    let pr_marker = "/pull/";
    let marker_idx = path.rfind(pr_marker)?;
    let project_path = &path[..marker_idx];
    let after_marker = &path[marker_idx + pr_marker.len()..];

    let iid_str = after_marker.split('/').next().unwrap_or(after_marker);
    let iid = iid_str.parse::<i64>().ok().filter(|&n| n > 0)?;

    let web_url = format!("{}://{}/{}", scheme, host_port.to_lowercase(), raw_path);

    let r = GitRemoteService::build_ref(&hostname, project_path)?;
    // GitHub projects are exactly `owner/repo`; deeper paths are not repos.
    if r.project_path.split('/').count() != 2 {
        return None;
    }
    Some(LinkedMergeRequest {
        provider: GitHost::GitHub,
        hostname: r.hostname,
        project_path: r.project_path,
        iid,
        web_url,
    })
}

/// Split an http(s) URL into `(scheme, host:port, host, path)`.
///
/// Credentials are stripped; the returned path keeps its query/fragment so
/// callers can rebuild a clean web URL.
fn split_web_url(url: &str) -> Option<(String, String, String, String)> {
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
        .unwrap_or(host_port)
        .trim()
        .to_string();
    if hostname.is_empty() {
        return None;
    }

    Some((
        scheme.to_string(),
        host_port.to_string(),
        hostname,
        raw_path.to_string(),
    ))
}

/// Pattern for GitLab merge request URLs embedded in arbitrary text. Matches
/// the same character set the Flutter client uses so assistant replies and
/// pasted messages are discovered consistently.
static GITLAB_MR_URL_RE: Lazy<Regex> = Lazy::new(|| {
    regex::RegexBuilder::new(r#"https?://[^\s<>"`{}|\\^`\[\]]+?/-/merge_requests/\d+"#)
        .case_insensitive(true)
        .build()
        .unwrap()
});

/// Pattern for GitHub pull request URLs embedded in arbitrary text.
static GITHUB_PR_URL_RE: Lazy<Regex> = Lazy::new(|| {
    regex::RegexBuilder::new(r#"https?://[^\s<>"`{}|\\^`\[\]]+?/pull/\d+"#)
        .case_insensitive(true)
        .build()
        .unwrap()
});

/// Extract and parse the first valid GitLab merge request URL found in text.
pub fn first_gitlab_merge_request_url(content: &str) -> Option<LinkedMergeRequest> {
    GITLAB_MR_URL_RE
        .find_iter(content)
        .find_map(|m| parse_gitlab_merge_request_url(m.as_str()))
}

/// Extract and parse the first valid GitHub pull request URL found in text.
pub fn first_github_pull_request_url(content: &str) -> Option<LinkedMergeRequest> {
    GITHUB_PR_URL_RE
        .find_iter(content)
        .find_map(|m| parse_github_pull_request_url(m.as_str()))
}

/// Extract and parse the first valid GitLab or GitHub merge/pull request URL
/// found in text, preferring whichever appears first.
pub fn first_merge_request_url(content: &str) -> Option<LinkedMergeRequest> {
    let gitlab = GITLAB_MR_URL_RE
        .find_iter(content)
        .filter_map(|m| parse_gitlab_merge_request_url(m.as_str()).map(|l| (m.start(), l)));
    let github = GITHUB_PR_URL_RE
        .find_iter(content)
        .filter_map(|m| parse_github_pull_request_url(m.as_str()).map(|l| (m.start(), l)));

    gitlab
        .chain(github)
        .min_by_key(|(pos, _)| *pos)
        .map(|(_, l)| l)
}

impl GitRemoteService {
    pub(super) fn api_host(host_kind: GitHost, hostname: &str) -> &str {
        if hostname.is_empty() {
            host_kind.default_hostname()
        } else {
            hostname
        }
    }

    pub(super) fn check_api_path(path: &str) -> Result<(), RemoteError> {
        let decoded = decode_api_path(path)?;
        if !decoded.starts_with("projects/") {
            return Err(RemoteError::StatusFailed(
                "only project api paths are supported".into(),
            ));
        }
        check_decoded_path(&decoded)
    }

    pub(super) fn check_github_api_path(path: &str) -> Result<(), RemoteError> {
        let decoded = decode_api_path(path)?;
        if decoded != "graphql" && !decoded.starts_with("repos/") {
            return Err(RemoteError::StatusFailed(
                "only repository api paths are supported".into(),
            ));
        }
        check_decoded_path(&decoded)
    }

    /// Percent-encode a GitHub `owner/repo` project path into a
    /// `repos/{owner}/{repo}` API path prefix. Repositories are exactly two
    /// path segments on GitHub.
    pub(super) fn github_repo_path(project_path: &str) -> Result<String, RemoteError> {
        validate_project_path(project_path)?;
        if project_path.split('/').count() != 2 {
            return Err(RemoteError::StatusFailed(
                "github project path must be owner/repo".into(),
            ));
        }
        let encoded = project_path
            .split('/')
            .map(|s| utf8_percent_encode(s, NON_ALPHANUMERIC).to_string())
            .collect::<Vec<_>>()
            .join("/");
        Ok(format!("repos/{encoded}"))
    }

    pub(super) fn build_ref(hostname: &str, path: &str) -> Option<RemoteProjectRef> {
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
        Some(RemoteProjectRef {
            hostname,
            project_path,
        })
    }
}

/// Validate a `group/project` style project path for use inside a git host
/// API path.
pub(super) fn validate_project_path(path: &str) -> Result<(), RemoteError> {
    if path.is_empty() {
        return Err(RemoteError::StatusFailed("project is required".into()));
    }
    if path.starts_with('/') || path.ends_with('/') {
        return Err(RemoteError::StatusFailed("invalid project path".into()));
    }
    if path.contains("..") || path.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(RemoteError::StatusFailed("invalid project path".into()));
    }
    let mut parts = path.split('/');
    let first = parts.next().unwrap_or("");
    if first.is_empty() || parts.any(|s| s.is_empty()) {
        return Err(RemoteError::StatusFailed("invalid project path".into()));
    }
    Ok(())
}

/// Fully percent-decode an API path so encoded traversal like `%2E%2E`
/// cannot slip through to the host API. Decoding repeats until stable to
/// also catch multiply-encoded input; anything still changing after ten
/// rounds is encoded more deeply than any legitimate path and refused.
fn decode_api_path(path: &str) -> Result<String, RemoteError> {
    let mut decoded = path.to_string();
    for _ in 0..10 {
        let next = percent_decode(decoded.as_bytes())
            .decode_utf8_lossy()
            .into_owned();
        if next == decoded {
            break;
        }
        decoded = next;
    }
    if percent_decode(decoded.as_bytes()).decode_utf8_lossy() != decoded {
        return Err(RemoteError::StatusFailed(
            "api path is encoded too deeply".into(),
        ));
    }
    if decoded.starts_with('/') {
        return Err(RemoteError::StatusFailed(
            "api path must not start with /".into(),
        ));
    }
    Ok(decoded)
}

/// Reject traversal and control characters in a decoded API path. `..` is
/// only traversal as a whole path segment; repo file names may legitimately
/// contain it (`logo..v2.png`) without leaving the API.
fn check_decoded_path(decoded: &str) -> Result<(), RemoteError> {
    let has_traversal = decoded
        .split(['/', '?', '#'])
        .any(|segment| segment == "..");
    if has_traversal || decoded.contains('\n') || decoded.contains('\r') || decoded.contains('\0') {
        return Err(RemoteError::StatusFailed(
            "invalid characters in api path".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_git_remote_url_handles_scp_style() {
        let r = parse_git_remote_url("git@gitlab.com:group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_git_remote_url("git@gitlab.example.com:group/subgroup/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/subgroup/project");
    }

    #[test]
    fn parse_git_remote_url_handles_https() {
        let r = parse_git_remote_url("https://gitlab.com/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_git_remote_url(
            "https://user:token@gitlab.example.com/group/subgroup/project.git",
        )
        .unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/subgroup/project");

        let r = parse_git_remote_url("https://gitlab.example.com:8443/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.example.com");
        assert_eq!(r.project_path, "group/project");

        let r = parse_git_remote_url("https://gitlab.com//group/project.git").unwrap();
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn parse_git_remote_url_handles_ssh_scheme_with_port() {
        let r = parse_git_remote_url("ssh://git@gitlab.com:22/group/project.git").unwrap();
        assert_eq!(r.hostname, "gitlab.com");
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn parse_git_remote_url_strips_trailing_dot_git_and_slash() {
        let r = parse_git_remote_url("https://gitlab.com/group/project/").unwrap();
        assert_eq!(r.project_path, "group/project");
    }

    #[test]
    fn parse_git_remote_url_rejects_garbage() {
        assert!(parse_git_remote_url("").is_none());
        assert!(parse_git_remote_url("not a url").is_none());
        assert!(parse_git_remote_url("https://gitlab.com/").is_none());
        assert!(parse_git_remote_url("https://gitlab.com/../project").is_none());
    }

    #[test]
    fn is_github_hostname_covers_cloud_and_enterprise_cloud() {
        assert!(is_github_hostname("github.com"));
        assert!(is_github_hostname("GITHUB.COM"));
        assert!(is_github_hostname("corp.ghe.com"));
        assert!(is_github_hostname("corp.ghe.localhost"));
        assert!(!is_github_hostname("gitlab.com"));
        assert!(!is_github_hostname("github.example.com"));
        assert!(!is_github_hostname("mygithub.com"));
    }

    #[test]
    fn detect_remote_classifies_providers() {
        let (host, r) = detect_remote("git@github.com:owner/repo.git").unwrap();
        assert_eq!(host, GitHost::GitHub);
        assert_eq!(r.hostname, "github.com");
        assert_eq!(r.project_path, "owner/repo");

        let (host, r) = detect_remote("https://gitlab.example.com/g/p.git").unwrap();
        assert_eq!(host, GitHost::GitLab);
        assert_eq!(r.project_path, "g/p");
    }

    #[test]
    fn parse_github_remote_url_accepts_github_hosts_only() {
        let r = parse_github_remote_url("git@github.com:owner/repo.git").unwrap();
        assert_eq!(r.hostname, "github.com");
        assert_eq!(r.project_path, "owner/repo");

        let r = parse_github_remote_url("https://corp.ghe.com/owner/repo").unwrap();
        assert_eq!(r.hostname, "corp.ghe.com");

        assert!(parse_github_remote_url("git@gitlab.com:owner/repo.git").is_none());
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
    fn api_host_defaults_to_each_provider() {
        assert_eq!(
            GitRemoteService::api_host(GitHost::GitLab, ""),
            "gitlab.com"
        );
        assert_eq!(
            GitRemoteService::api_host(GitHost::GitHub, ""),
            "github.com"
        );
        assert_eq!(
            GitRemoteService::api_host(GitHost::GitLab, "gitlab.example.com"),
            "gitlab.example.com"
        );
        assert_eq!(
            GitRemoteService::api_host(GitHost::GitHub, "corp.ghe.com"),
            "corp.ghe.com"
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
        // Percent-encoded traversal is validated after decoding.
        assert!(GitRemoteService::check_api_path("projects/foo/%2E%2E/bar").is_err());
        assert!(GitRemoteService::check_api_path("projects/%2e%2E/user").is_err());
        assert!(GitRemoteService::check_api_path("projects/%252E%252E/x").is_err());
        assert!(GitRemoteService::check_api_path("%2Fprojects/foo").is_err());
        assert!(GitRemoteService::check_api_path("projects/foo%0Abar").is_err());
        // Encoded more deeply than the decode cap is refused outright.
        let mut deep = "%2E".to_string();
        for _ in 0..11 {
            deep = deep.replace('%', "%25");
        }
        assert!(GitRemoteService::check_api_path(&format!("projects/{deep}/x")).is_err());
    }

    #[test]
    fn check_github_api_path_allows_repos_and_graphql() {
        assert!(GitRemoteService::check_github_api_path("repos/o/r/pulls/1").is_ok());
        assert!(GitRemoteService::check_github_api_path("graphql").is_ok());
        assert!(GitRemoteService::check_github_api_path(
            "repos/o/r/actions/runs?head_sha=abc&per_page=30"
        )
        .is_ok());
        assert!(GitRemoteService::check_github_api_path("projects/g%2Fp/issues").is_err());
        assert!(GitRemoteService::check_github_api_path("user/repos").is_err());
        assert!(GitRemoteService::check_github_api_path("/repos/o/r").is_err());
        assert!(GitRemoteService::check_github_api_path("repos/o/../r").is_err());
        assert!(GitRemoteService::check_github_api_path("repos/%2E%2E/r").is_err());
        assert!(GitRemoteService::check_github_api_path("graphql/mutation").is_err());
    }

    #[test]
    fn check_decoded_path_allows_dots_inside_file_names() {
        // `..` inside a path segment is a legal git file name, not traversal.
        assert!(GitRemoteService::check_api_path(
            "projects/g%2Fp/repository/files/icons%2Flogo..v2.png?ref=abc123"
        )
        .is_ok());
        assert!(GitRemoteService::check_api_path(
            "projects/g%2Fp/repository/files/a%2Fb.png?ref=x"
        )
        .is_ok());
        // Whole `..` segments are still rejected, including inside the query,
        // while a `..` query value alone is harmless and passes through.
        assert!(GitRemoteService::check_api_path("projects/x/files/../y").is_err());
        assert!(GitRemoteService::check_api_path("projects/g%2Fp/files/a?ref=a/../b").is_err());
        assert!(GitRemoteService::check_api_path("projects/g%2Fp/files/a?ref=..").is_ok());
    }

    #[test]
    fn github_repo_path_builds_repos_prefix() {
        let p = GitRemoteService::github_repo_path("owner/repo").unwrap();
        assert_eq!(p, "repos/owner/repo");
        let p = GitRemoteService::github_repo_path("my-org/my.repo").unwrap();
        assert_eq!(p, "repos/my%2Dorg/my%2Erepo");
        assert!(GitRemoteService::github_repo_path("a/b/c").is_err());
        assert!(GitRemoteService::github_repo_path("").is_err());
        assert!(GitRemoteService::github_repo_path("a b/c").is_err());
    }

    #[test]
    fn parse_gitlab_merge_request_url_extracts_host_path_and_iid() {
        let r = parse_gitlab_merge_request_url(
            "https://gitlab.example.com/group/project/-/merge_requests/12",
        )
        .unwrap();
        assert_eq!(r.provider, GitHost::GitLab);
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
    fn parse_github_pull_request_url_extracts_host_repo_and_number() {
        let r = parse_github_pull_request_url("https://github.com/owner/repo/pull/12").unwrap();
        assert_eq!(r.provider, GitHost::GitHub);
        assert_eq!(r.hostname, "github.com");
        assert_eq!(r.project_path, "owner/repo");
        assert_eq!(r.iid, 12);
        assert_eq!(r.web_url, "https://github.com/owner/repo/pull/12");
    }

    #[test]
    fn parse_github_pull_request_url_accepts_enterprise_hosts_and_trailing_paths() {
        let r = parse_github_pull_request_url("https://corp.ghe.com/a/b/pull/7/files").unwrap();
        assert_eq!(r.provider, GitHost::GitHub);
        assert_eq!(r.hostname, "corp.ghe.com");
        assert_eq!(r.project_path, "a/b");
        assert_eq!(r.iid, 7);
    }

    #[test]
    fn parse_github_pull_request_url_rejects_non_github_and_invalid() {
        // Any host is accepted so GitHub Enterprise domains work; the
        // provider check happens when the link is resolved.
        let r = parse_github_pull_request_url("https://git.acme.corp/o/r/pull/12").unwrap();
        assert_eq!(r.provider, GitHost::GitHub);
        assert_eq!(r.hostname, "git.acme.corp");
        assert!(parse_github_pull_request_url(
            "https://gitlab.com/group/project/-/merge_requests/12"
        )
        .is_none());
        assert!(parse_github_pull_request_url("").is_none());
        assert!(parse_github_pull_request_url("https://github.com").is_none());
        assert!(parse_github_pull_request_url("https://github.com/o/r").is_none());
        assert!(parse_github_pull_request_url("https://github.com/o/r/pull/abc").is_none());
        // GitHub repos are exactly owner/repo.
        assert!(parse_github_pull_request_url("https://github.com/a/pull/1").is_none());
        assert!(parse_github_pull_request_url("https://github.com/a/b/c/pull/1").is_none());
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

    #[test]
    fn first_github_pull_request_url_extracts_first_valid() {
        let text = "Opened https://github.com/owner/repo/pull/99 for review";
        let r = first_github_pull_request_url(text).unwrap();
        assert_eq!(r.iid, 99);
        assert_eq!(r.provider, GitHost::GitHub);
        assert_eq!(r.project_path, "owner/repo");
    }

    #[test]
    fn first_merge_request_url_picks_earliest_match() {
        let text = "See https://gitlab.com/g/p/-/merge_requests/3 and \
                    https://github.com/o/r/pull/8";
        let r = first_merge_request_url(text).unwrap();
        assert_eq!(r.provider, GitHost::GitLab);
        assert_eq!(r.iid, 3);

        let text = "See https://github.com/o/r/pull/8 and \
                    https://gitlab.com/g/p/-/merge_requests/3";
        let r = first_merge_request_url(text).unwrap();
        assert_eq!(r.provider, GitHost::GitHub);
        assert_eq!(r.iid, 8);

        assert!(first_merge_request_url("no links").is_none());
    }

    #[test]
    fn linked_merge_request_defaults_provider_to_gitlab() {
        // Rows persisted before the provider field existed deserialize as GitLab.
        let raw = r#"{"hostname":"gitlab.com","project_path":"g/p","iid":4,"web_url":"https://gitlab.com/g/p/-/merge_requests/4"}"#;
        let l: LinkedMergeRequest = serde_json::from_str(raw).unwrap();
        assert_eq!(l.provider, GitHost::GitLab);

        let json = serde_json::to_value(&l).unwrap();
        assert_eq!(json["provider"], "gitlab");

        let gh = LinkedMergeRequest {
            provider: GitHost::GitHub,
            hostname: "github.com".into(),
            project_path: "o/r".into(),
            iid: 2,
            web_url: "https://github.com/o/r/pull/2".into(),
        };
        let json = serde_json::to_value(&gh).unwrap();
        assert_eq!(json["provider"], "github");
    }
}
