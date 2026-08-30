//! Server-side git clone support.
//!
//! Clones a remote repository into the configured clone root using the layout
//! `$clone_root/<platform>/<owner>/<repo>/`. Paths are sanitised to prevent
//! traversal and the GitLab CLI auth context is reused for private GitLab
//! repositories.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use percent_encoding::percent_decode_str;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

use crate::db::NewProject;
use crate::git::{GitRemoteService, GitService};
use crate::security::paths;

/// Possible errors from clone operations.
#[derive(Debug, thiserror::Error)]
pub enum CloneError {
    #[error("git support is not enabled on this backend")]
    NotEnabled,
    #[error("clone root is not configured; ask the owner to set it in Settings")]
    MissingCloneRoot,
    #[error("malformed remote URL")]
    MalformedUrl,
    #[error("remote URL has no owner")]
    NoOwner,
    #[error("invalid owner or repo name")]
    InvalidSegment,
    #[error("clone target already exists")]
    AlreadyExists,
    #[error("clone failed: {0}")]
    CloneFailed(String),
    #[error("timeout")]
    Timeout,
}

impl CloneError {
    pub fn status_code(&self) -> axum::http::StatusCode {
        use axum::http::StatusCode;
        match self {
            CloneError::NotEnabled => StatusCode::NOT_FOUND,
            CloneError::MissingCloneRoot
            | CloneError::MalformedUrl
            | CloneError::NoOwner
            | CloneError::InvalidSegment => StatusCode::BAD_REQUEST,
            CloneError::AlreadyExists => StatusCode::CONFLICT,
            CloneError::Timeout => StatusCode::GATEWAY_TIMEOUT,
            CloneError::CloneFailed(_) => StatusCode::BAD_GATEWAY,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scheme {
    Http,
    Https,
    Ssh,
    Git,
    File,
}

/// A parsed remote repository URL.
#[derive(Debug, Clone)]
pub struct ParsedRemote {
    pub clean_url: String,
    pub host: String,
    pub host_with_port: String,
    pub raw_project_path: String,
    pub owner: String,
    pub repo: String,
    pub platform: String,
    pub is_gitlab: bool,
}

/// Clone [remote_url] into the configured clone root and create a project row.
///
/// The destination is always under the owner-configured clone root, even for
/// non-owner users. The function returns the canonical absolute path of the
/// newly cloned repository.
pub async fn clone_repo(
    git: &GitService,
    git_remote: &GitRemoteService,
    db: &crate::db::Db,
    config: &crate::config::Config,
    user_id: i64,
    remote_url: &str,
) -> Result<PathBuf, CloneError> {
    let parsed = parse_remote_url(remote_url)?;

    let root = db
        .get_clone_root(user_id)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?
        .ok_or(CloneError::MissingCloneRoot)?;
    let root = paths::normalize_path(&root, &config.home_dir);
    let clone_root =
        paths::resolve(Path::new(&root), None, None).ok_or(CloneError::MissingCloneRoot)?;

    let target = clone_root
        .join(&parsed.platform)
        .join(&parsed.owner)
        .join(&parsed.repo);

    let resolved_target = paths::resolve(&target, None, Some(&[clone_root.clone()]))
        .ok_or(CloneError::InvalidSegment)?;

    if tokio::fs::try_exists(&resolved_target)
        .await
        .unwrap_or(false)
    {
        return Err(CloneError::AlreadyExists);
    }

    if db
        .get_project_by_path(user_id, &resolved_target.to_string_lossy())
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?
        .is_some()
    {
        return Err(CloneError::AlreadyExists);
    }

    let project_name = unique_project_name(db, user_id, &parsed.owner, &parsed.repo).await?;
    let position = db
        .next_project_position(user_id)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?;

    let project = db
        .create_project(NewProject {
            user_id,
            name: project_name,
            path: resolved_target.to_string_lossy().to_string(),
            position,
            project_type: "generic".to_string(),
        })
        .await
        .map_err(|e| CloneError::CloneFailed(format!("failed to create project: {e}")))?;

    // Create parent directories so git clone has a place to write the repo.
    if let Some(parent) = resolved_target.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            let _ = db.delete_project(project.id, user_id).await;
            return Err(CloneError::CloneFailed(format!(
                "cannot create parent directory: {e}"
            )));
        }
    }

    let clone_url = build_clone_url(git_remote, user_id, &parsed).await;

    let git_bin = git.binary().ok_or(CloneError::NotEnabled)?;
    let mut cmd = Command::new(git_bin);
    cmd.env("LC_ALL", "C")
        .env("GCM_INTERACTIVE", "never")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env("GIT_ASKPASS", "false")
        .env("HOME", &config.home_dir)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .arg("clone")
        .arg("--")
        .arg(&clone_url)
        .arg(&resolved_target);

    match run_git_clone(&mut cmd, Duration::from_secs(300)).await {
        Ok(()) => {}
        Err(e) => {
            let _ = db.delete_project(project.id, user_id).await;
            let _ = tokio::fs::remove_dir_all(&resolved_target).await;
            return Err(e);
        }
    }

    let final_path = tokio::fs::canonicalize(&resolved_target)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("clone did not create directory: {e}")))?;
    if !paths::is_within(&final_path, &clone_root) {
        let _ = db.delete_project(project.id, user_id).await;
        return Err(CloneError::InvalidSegment);
    }

    let project_type = crate::projects::detect::detect_project_type(&final_path);
    if let Err(e) = db.set_project_type(project.id, user_id, project_type).await {
        tracing::warn!(error = %e, project_id = %project.id, "failed to set project type");
    }

    Ok(final_path)
}

fn parse_remote_url(url: &str) -> Result<ParsedRemote, CloneError> {
    let raw = url.trim().to_string();
    if raw.is_empty() {
        return Err(CloneError::MalformedUrl);
    }

    let clean = if let Some(i) = raw.find(['?', '#']) {
        raw[..i].to_string()
    } else {
        raw.clone()
    };
    if clean.is_empty() {
        return Err(CloneError::MalformedUrl);
    }

    let (_scheme, host_with_port, raw_project_path) = parse_core(&clean)?;
    let host = host_without_port(&host_with_port)?;
    let platform = platform_for_host(&host);
    let is_gitlab = platform == "gitlab";

    let project_path = raw_project_path.trim_matches('/');
    let segments: Vec<&str> = project_path.split('/').filter(|s| !s.is_empty()).collect();
    if segments.len() < 2 {
        return Err(CloneError::NoOwner);
    }

    for s in &segments {
        decode_and_validate_segment(s)?;
    }

    let owner = decode_and_validate_segment(segments.first().unwrap())?;
    let repo = {
        let last = segments.last().unwrap();
        let mut r = last.to_string();
        if r.ends_with(".git") {
            r.truncate(r.len() - 4);
        }
        decode_and_validate_segment(&r)?
    };

    Ok(ParsedRemote {
        clean_url: clean,
        host,
        host_with_port,
        raw_project_path,
        owner,
        repo,
        platform,
        is_gitlab,
    })
}

fn parse_core(clean: &str) -> Result<(Scheme, String, String), CloneError> {
    // scp-like git@host:path
    if let Some(rest) = clean.strip_prefix("git@") {
        let (host, path) = rest.split_once(':').ok_or(CloneError::MalformedUrl)?;
        if host.is_empty() || path.is_empty() {
            return Err(CloneError::MalformedUrl);
        }
        return Ok((Scheme::Ssh, host.to_string(), path.to_string()));
    }

    // file:/// or file://host/
    if let Some(rest) = clean.strip_prefix("file://") {
        if let Some(path) = rest.strip_prefix('/') {
            if path.is_empty() {
                return Err(CloneError::MalformedUrl);
            }
            return Ok((Scheme::File, "localhost".to_string(), path.to_string()));
        }
        let (host, path) = rest.split_once('/').ok_or(CloneError::MalformedUrl)?;
        if host.is_empty() || path.is_empty() {
            return Err(CloneError::MalformedUrl);
        }
        return Ok((Scheme::File, host.to_string(), path.to_string()));
    }

    // ssh://[user@]host[:port]/path
    if let Some(rest) = clean.strip_prefix("ssh://") {
        let rest = rest.strip_prefix("git@").unwrap_or(rest);
        let (host_and_port, path) = rest.split_once('/').ok_or(CloneError::MalformedUrl)?;
        if host_and_port.is_empty() || path.is_empty() {
            return Err(CloneError::MalformedUrl);
        }
        return Ok((Scheme::Ssh, host_and_port.to_string(), path.to_string()));
    }

    // git://host[:port]/path
    if let Some(rest) = clean.strip_prefix("git://") {
        let (host_and_port, path) = rest.split_once('/').ok_or(CloneError::MalformedUrl)?;
        if host_and_port.is_empty() || path.is_empty() {
            return Err(CloneError::MalformedUrl);
        }
        return Ok((Scheme::Git, host_and_port.to_string(), path.to_string()));
    }

    // http://[auth@]host[:port]/path
    if let Some(rest) = clean.strip_prefix("http://") {
        let (host_and_port, path) = parse_httpish(rest)?;
        return Ok((Scheme::Http, host_and_port, path));
    }

    // https://[auth@]host[:port]/path
    if let Some(rest) = clean.strip_prefix("https://") {
        let (host_and_port, path) = parse_httpish(rest)?;
        return Ok((Scheme::Https, host_and_port, path));
    }

    // Plain absolute path — git accepts these as file URLs.
    if Path::new(clean).is_absolute() {
        return Ok((
            Scheme::File,
            "localhost".to_string(),
            clean.trim_start_matches('/').to_string(),
        ));
    }

    Err(CloneError::MalformedUrl)
}

fn parse_httpish(rest: &str) -> Result<(String, String), CloneError> {
    let after_auth = match rest.split_once('@') {
        Some((_, h_p)) => h_p,
        None => rest,
    };
    let (host_and_port, path) = after_auth.split_once('/').ok_or(CloneError::MalformedUrl)?;
    if host_and_port.is_empty() {
        return Err(CloneError::MalformedUrl);
    }
    Ok((host_and_port.to_string(), path.to_string()))
}

fn host_without_port(host_and_port: &str) -> Result<String, CloneError> {
    let host = if host_and_port.starts_with('[') {
        let end = host_and_port.find(']').ok_or(CloneError::MalformedUrl)?;
        let h = host_and_port[..=end].to_string();
        if h.is_empty() {
            return Err(CloneError::MalformedUrl);
        }
        h
    } else if let Some((h, p)) = host_and_port.rsplit_once(':') {
        if p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() {
            h.to_string()
        } else {
            host_and_port.to_string()
        }
    } else {
        host_and_port.to_string()
    };
    if host.is_empty() {
        return Err(CloneError::MalformedUrl);
    }
    Ok(host.to_lowercase())
}

fn platform_for_host(host: &str) -> String {
    let lower = host.to_lowercase();
    match lower.as_str() {
        "gitlab.com" => "gitlab".to_string(),
        "github.com" => "github".to_string(),
        "localhost" => "local".to_string(),
        _ => lower,
    }
}

fn decode_and_validate_segment(s: &str) -> Result<String, CloneError> {
    let decoded = percent_decode_str(s).decode_utf8_lossy().to_string();
    if decoded.is_empty() {
        return Err(CloneError::InvalidSegment);
    }
    if decoded == "." || decoded == ".." {
        return Err(CloneError::InvalidSegment);
    }
    if decoded.contains("..") || decoded.contains('/') || decoded.contains('\\') {
        return Err(CloneError::InvalidSegment);
    }
    for c in decoded.chars() {
        if c == '\0' || c == '\n' || c == '\r' || c == '\t' {
            return Err(CloneError::InvalidSegment);
        }
    }
    Ok(decoded)
}

async fn build_clone_url(
    git_remote: &GitRemoteService,
    user_id: i64,
    parsed: &ParsedRemote,
) -> String {
    if parsed.is_gitlab {
        match git_remote
            .gitlab_token_for_host(user_id, &parsed.host)
            .await
        {
            Ok(Some(token)) => {
                return format!(
                    "https://oauth2:{}@{}/{}",
                    token, parsed.host_with_port, parsed.raw_project_path
                );
            }
            Ok(None) => {}
            Err(e) => {
                tracing::warn!(error = %e, "failed to get gitlab token; using plain clone");
            }
        }
    }
    parsed.clean_url.clone()
}

async fn unique_project_name(
    db: &crate::db::Db,
    user_id: i64,
    owner: &str,
    repo: &str,
) -> Result<String, CloneError> {
    let base = format!("{owner}/{repo}");
    if db
        .get_project_by_name(user_id, &base)
        .await
        .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?
        .is_none()
    {
        return Ok(base);
    }
    for n in 2..1000 {
        let candidate = format!("{owner}/{repo}-{n}");
        if db
            .get_project_by_name(user_id, &candidate)
            .await
            .map_err(|e| CloneError::CloneFailed(format!("database error: {e}")))?
            .is_none()
        {
            return Ok(candidate);
        }
    }
    Err(CloneError::CloneFailed(
        "could not find a unique project name".to_string(),
    ))
}

async fn run_git_clone(cmd: &mut Command, max: Duration) -> Result<(), CloneError> {
    let mut child = cmd
        .spawn()
        .map_err(|e| CloneError::CloneFailed(format!("failed to spawn git: {e}")))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| CloneError::CloneFailed("failed to capture stderr".to_string()))?;
    let mut reader = BufReader::new(stderr).lines();
    let mut stderr_lines: Vec<String> = Vec::with_capacity(50);

    let read_fut = async {
        loop {
            match reader.next_line().await {
                Ok(Some(line)) => {
                    let line = redact_token(&line);
                    tracing::info!(%line, "git clone progress");
                    if stderr_lines.len() >= 50 {
                        stderr_lines.remove(0);
                    }
                    stderr_lines.push(line);
                }
                Ok(None) => break,
                Err(e) => {
                    return Err(CloneError::CloneFailed(format!(
                        "failed to read git stderr: {e}"
                    )))
                }
            }
        }
        Ok(())
    };

    match timeout(max, read_fut).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return Err(e),
        Err(_) => {
            let _ = child.start_kill();
            return Err(CloneError::Timeout);
        }
    }

    drop(reader);
    let status = child
        .wait()
        .await
        .map_err(|e| CloneError::CloneFailed(format!("failed to wait for git: {e}")))?;
    if !status.success() {
        let msg = stderr_lines.join("\n");
        return Err(CloneError::CloneFailed(msg));
    }
    Ok(())
}

fn redact_token(s: &str) -> String {
    // Redact GitLab oauth2 tokens from error messages so they do not leak
    // back to the UI or tracing in plain text.
    let re = regex::Regex::new(r"oauth2:[^@\s]+@").unwrap();
    re.replace_all(s, "oauth2:***@").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_gitlab_https() {
        let p = parse_remote_url("https://gitlab.com/HttpAnimations/Avile.git").unwrap();
        assert_eq!(p.platform, "gitlab");
        assert_eq!(p.owner, "HttpAnimations");
        assert_eq!(p.repo, "Avile");
        assert_eq!(p.host_with_port, "gitlab.com");
        assert_eq!(p.raw_project_path, "HttpAnimations/Avile.git");
    }

    #[test]
    fn parses_github_ssh() {
        let p = parse_remote_url("git@github.com:Foo/Bar.git").unwrap();
        assert_eq!(p.platform, "github");
        assert_eq!(p.owner, "Foo");
        assert_eq!(p.repo, "Bar");
        assert_eq!(p.host_with_port, "github.com");
    }

    #[test]
    fn strips_git_suffix() {
        let p = parse_remote_url("https://gitlab.com/owner/repo.git").unwrap();
        assert_eq!(p.repo, "repo");
    }

    #[test]
    fn preserves_casing() {
        let p = parse_remote_url("https://gitlab.com/HttpAnimations/Avile").unwrap();
        assert_eq!(p.owner, "HttpAnimations");
        assert_eq!(p.repo, "Avile");
    }

    #[test]
    fn rejects_single_segment() {
        assert!(matches!(
            parse_remote_url("https://gitlab.com/foo"),
            Err(CloneError::NoOwner)
        ));
    }

    #[test]
    fn rejects_empty_url() {
        assert!(matches!(
            parse_remote_url(""),
            Err(CloneError::MalformedUrl)
        ));
    }

    #[test]
    fn rejects_traversal_in_owner() {
        assert!(parse_remote_url("https://gitlab.com/../foo/repo.git").is_err());
    }

    #[test]
    fn rejects_encoded_separators() {
        assert!(parse_remote_url("https://gitlab.com/foo%2Fbar/repo.git").is_err());
    }

    #[test]
    fn parses_file_url() {
        let p = parse_remote_url("file:///owner/repo.git").unwrap();
        assert_eq!(p.platform, "local");
        assert_eq!(p.owner, "owner");
        assert_eq!(p.repo, "repo");
    }

    #[test]
    fn redacts_token() {
        assert_eq!(
            redact_token("fatal: https://oauth2:abc123@gitlab.com/foo"),
            "fatal: https://oauth2:***@gitlab.com/foo"
        );
    }
}
