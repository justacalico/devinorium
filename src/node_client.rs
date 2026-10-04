//! Hub-side client for a paired satellite node.
//!
//! Everything the hub asks a satellite to do goes through [`NodeClient`]:
//! provider runs, file and git operations, terminals, clones and probes.
//! The client carries the node's base URL and the bearer token issued at
//! pairing; `RemoteGit` wraps it with the same method surface as
//! [`GitService`] so callers can hold a [`GitBackend`] and not care which
//! machine the repo lives on.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::db::federation_nodes::FederationNodeRow;
use crate::git::{Branch, ChangeList, CommitPage, CommitResult, GitError, RepoStatus, Worktree};
use crate::node::{
    CallbackOutcome, CallbackRequest, CloneNodeRequest, CloneNodeResponse, CreateNodeTerminal,
    NodeError, NodeInfo, PairRequest, PairResponse, ProviderOpRequest, RunRequest, StatOut,
    StatRequest, StatResponse,
};

/// A paired node's connection details.
#[derive(Clone)]
pub struct NodeClient {
    client: reqwest::Client,
    base_url: String,
    token: String,
    /// Hub-side username forwarded for the satellite's logs.
    proxy_user: Option<String>,
}

/// Percent-encode a value that goes inside a path segment. Node-supplied
/// ids are trusted less than hub-generated ones.
fn enc_seg(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// Response headers that must not be relayed back to a hub client. Same
/// rationale as the old reverse proxy: a node must not set cookies on the
/// hub's origin or inject policy headers.
const STRIPPED_RESPONSE_HEADERS: &[&str] = &[
    "connection",
    "transfer-encoding",
    "keep-alive",
    "trailer",
    "trailers",
    "upgrade",
    "content-length",
    "set-cookie",
    "clear-site-data",
    "www-authenticate",
    "alt-svc",
    "location",
    "content-security-policy",
    "content-security-policy-report-only",
    "x-frame-options",
    "etag",
    "last-modified",
    "cache-control",
    "expires",
    "age",
    "pragma",
    "vary",
];

impl NodeClient {
    pub fn new(client: reqwest::Client, base_url: &str, token: &str) -> Self {
        Self {
            client,
            base_url: base_url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            proxy_user: None,
        }
    }

    /// Build a client for a stored node row on the bounded client (10
    /// minute ceiling). Returns `None` when the row has no token
    /// (pre-pairing rows cannot exist in this model, so this is defensive).
    /// Runs and other long-lived streams use [`for_node_stream`].
    pub fn for_node(_state: &crate::AppState, node: &FederationNodeRow) -> Option<Self> {
        let token = node.token.as_deref().filter(|t| !t.is_empty())?;
        Some(Self::new(
            crate::federation::bounded_http_client(),
            &node.base_url,
            token,
        ))
    }

    /// Same on the unbounded streaming client: provider runs stream events
    /// for the life of a turn and must never hit a total timeout.
    pub fn for_node_stream(state: &crate::AppState, node: &FederationNodeRow) -> Option<Self> {
        let token = node.token.as_deref().filter(|t| !t.is_empty())?;
        Some(Self::new(state.http_client.clone(), &node.base_url, token))
    }

    /// Same but on the short-timeout client for lightweight calls.
    pub fn for_node_short(_state: &crate::AppState, node: &FederationNodeRow) -> Option<Self> {
        let token = node.token.as_deref().filter(|t| !t.is_empty())?;
        Some(Self::new(
            crate::federation::short_http_client(),
            &node.base_url,
            token,
        ))
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn url(&self, path: &str) -> String {
        format!(
            "{}/api/node/{}",
            self.base_url,
            path.trim_start_matches('/')
        )
    }

    fn authed(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let req = req.bearer_auth(&self.token);
        match &self.proxy_user {
            Some(u) => req.header(crate::federation::PROXY_USER_HEADER, u.as_str()),
            None => req,
        }
    }

    /// Tag the hub user on whose behalf this call runs; the satellite
    /// logs it on forwarded requests.
    pub fn with_proxy_user(&self, username: &str) -> Self {
        let mut c = self.clone();
        c.proxy_user = Some(username.to_string());
        c
    }

    /// `GET /api/node/info`. Unauthenticated server-side, but harmless to
    /// send the token.
    pub async fn info(&self) -> anyhow::Result<NodeInfo> {
        let resp = self
            .authed(self.client.get(self.url("info")))
            .send()
            .await?;
        if !resp.status().is_success() {
            anyhow::bail!("node info failed: {}", resp.status());
        }
        Ok(resp.json::<NodeInfo>().await?)
    }

    /// Exchange a pairing code for a node token. `base_url` must already be
    /// a cleaned origin URL.
    pub async fn pair(
        client: &reqwest::Client,
        base_url: &str,
        code: &str,
    ) -> Result<PairResponse, NodeCallError> {
        let url = format!("{}/api/node/pair", base_url.trim_end_matches('/'));
        let resp = client
            .post(url)
            .json(&PairRequest {
                code: code.to_string(),
            })
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        resp.json::<PairResponse>()
            .await
            .map_err(NodeCallError::transport)
    }

    /// `POST /api/node/run`; the response body is the NodeEvent SSE stream.
    pub async fn run(&self, req: &RunRequest) -> Result<reqwest::Response, NodeCallError> {
        let resp = self
            .authed(self.client.post(self.url("run")).json(req))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(resp)
    }

    /// Resolve a pending permission/ask request on the satellite.
    pub async fn callback(
        &self,
        request_id: &str,
        outcome: &CallbackOutcome,
    ) -> Result<(), NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .post(self.url("callback"))
                    .json(&CallbackRequest {
                        request_id: request_id.to_string(),
                        outcome: outcome.clone(),
                    }),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// Ask the satellite to cancel a running provider turn.
    pub async fn cancel_run(&self, run_id: &str) -> Result<(), NodeCallError> {
        let resp = self
            .authed(self.client.post(self.url(&format!("runs/{run_id}/cancel"))))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// Stat a batch of paths on the node.
    pub async fn fs_stat(
        &self,
        root: Option<&str>,
        paths: &[String],
    ) -> Result<HashMap<String, StatOut>, NodeCallError> {
        let resp = self
            .authed(self.client.post(self.url("files/stat")).json(&StatRequest {
                root: root.map(str::to_string),
                paths: paths.to_vec(),
            }))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(resp
            .json::<StatResponse>()
            .await
            .map_err(NodeCallError::transport)?
            .results)
    }

    /// Read a file on the node, returning (mime, bytes). `None` when the
    /// path is missing or unreadable.
    pub async fn fs_read(&self, root: &str, path: &str) -> Option<(String, Vec<u8>)> {
        let mut url = reqwest::Url::parse(&self.url("files/content")).ok()?;
        url.query_pairs_mut()
            .append_pair("root", root)
            .append_pair("path", path);
        let resp = self.authed(self.client.get(url)).send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let v: serde_json::Value = resp.json().await.ok()?;
        let b64 = v["base64"].as_str()?;
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
        let mime = v["mime"]
            .as_str()
            .unwrap_or("application/octet-stream")
            .to_string();
        Some((mime, bytes))
    }

    /// Create a directory (with parents) on the node.
    pub async fn fs_mkdir(&self, root: Option<&str>, path: &str) -> Result<(), NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .post(self.url("files/dir"))
                    .json(&serde_json::json!({
                        "root": root,
                        "path": path,
                    })),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// Remove a file or directory on the node.
    pub async fn fs_delete(&self, root: Option<&str>, path: &str) -> Result<(), NodeCallError> {
        let mut url =
            reqwest::Url::parse(&self.url("files/delete")).map_err(|e| NodeCallError::Remote {
                kind: "config".into(),
                message: format!("bad node url: {e}"),
            })?;
        url.query_pairs_mut().append_pair("path", path);
        if let Some(root) = root {
            url.query_pairs_mut().append_pair("root", root);
        }
        let resp = self
            .authed(self.client.delete(url))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// Forward a GET to a `/api/node/files*` endpoint and relay the
    /// response verbatim (status, content-type, body).
    pub async fn forward_get(
        &self,
        path: &str,
        query: &[(String, String)],
    ) -> Result<Response, NodeCallError> {
        let mut url = reqwest::Url::parse(&self.url(path)).map_err(|e| NodeCallError::Remote {
            kind: "config".into(),
            message: format!("bad node url: {e}"),
        })?;
        url.query_pairs_mut().extend_pairs(query.iter());
        let resp = self
            .authed(self.client.get(url))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        Ok(relay_response(resp))
    }

    /// Forward a request with a raw body (JSON, multipart, ...) to a node
    /// endpoint and relay the response verbatim.
    pub async fn forward_body(
        &self,
        method: reqwest::Method,
        path: &str,
        query: &[(String, String)],
        content_type: Option<String>,
        body: Vec<u8>,
    ) -> Result<Response, NodeCallError> {
        let mut url = reqwest::Url::parse(&self.url(path)).map_err(|e| NodeCallError::Remote {
            kind: "config".into(),
            message: format!("bad node url: {e}"),
        })?;
        url.query_pairs_mut().extend_pairs(query.iter());
        let mut req = self.authed(self.client.request(method, url)).body(body);
        if let Some(ct) = content_type {
            if let Ok(v) = HeaderValue::from_str(&ct) {
                req = req.header(header::CONTENT_TYPE, v);
            }
        }
        let resp = req.send().await.map_err(NodeCallError::transport)?;
        Ok(relay_response(resp))
    }

    /// Forward a multipart form to a node endpoint (used for file upload).
    pub async fn post_multipart(
        &self,
        path: &str,
        query: &[(String, String)],
        form: reqwest::multipart::Form,
    ) -> Result<Response, NodeCallError> {
        let mut url = reqwest::Url::parse(&self.url(path)).map_err(|e| NodeCallError::Remote {
            kind: "config".into(),
            message: format!("bad node url: {e}"),
        })?;
        url.query_pairs_mut().extend_pairs(query.iter());
        let resp = self
            .authed(self.client.post(url).multipart(form))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        Ok(relay_response(resp))
    }

    /// `POST /api/node/terminal/sessions`.
    pub async fn create_terminal(
        &self,
        cwd: &Path,
        thread_id: &str,
    ) -> Result<String, NodeCallError> {
        let resp =
            self.authed(self.client.post(self.url("terminal/sessions")).json(
                &CreateNodeTerminal {
                    cwd: cwd.to_path_buf(),
                    thread_id: thread_id.to_string(),
                },
            ))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        let v: serde_json::Value = resp.json().await.map_err(NodeCallError::transport)?;
        Ok(v["id"].as_str().unwrap_or_default().to_string())
    }

    /// `DELETE /api/node/terminal/sessions/:id`.
    pub async fn delete_terminal(&self, session_id: &str) -> Result<(), NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .delete(self.url(&format!("terminal/sessions/{}", enc_seg(session_id)))),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// WebSocket URL for a terminal session on the node.
    pub fn terminal_ws_url(&self, session_id: &str) -> String {
        let http = format!(
            "{}/api/node/terminal/sessions/{}/ws",
            self.base_url,
            enc_seg(session_id)
        );
        if let Some(rest) = http.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = http.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            http
        }
    }

    /// `POST /api/node/clone`.
    pub async fn clone_repo(&self, url: &str) -> Result<String, NodeCallError> {
        let resp = self
            .authed(self.client.post(self.url("clone")).json(&CloneNodeRequest {
                url: url.to_string(),
            }))
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(resp
            .json::<CloneNodeResponse>()
            .await
            .map_err(NodeCallError::transport)?
            .path)
    }

    /// `POST /api/node/provider/models`.
    pub async fn provider_models(
        &self,
        provider_id: &str,
        command: &str,
        default_model: &str,
    ) -> Result<Vec<crate::providers::ModelInfo>, NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .post(self.url("provider/models"))
                    .json(&ProviderOpRequest {
                        id: provider_id.to_string(),
                        command: command.to_string(),
                        default_model: default_model.to_string(),
                    }),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        resp.json().await.map_err(NodeCallError::transport)
    }

    /// `POST /api/node/provider/health`.
    pub async fn provider_health(
        &self,
        provider_id: &str,
        command: &str,
        default_model: &str,
    ) -> Result<(), NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .post(self.url("provider/health"))
                    .json(&ProviderOpRequest {
                        id: provider_id.to_string(),
                        command: command.to_string(),
                        default_model: default_model.to_string(),
                    }),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        Ok(())
    }

    /// `POST /api/node/skills/list`.
    pub async fn skills_list(
        &self,
        working_dir: &Path,
    ) -> Result<serde_json::Value, NodeCallError> {
        let resp = self
            .authed(
                self.client
                    .post(self.url("skills/list"))
                    .json(&serde_json::json!({"working_dir": working_dir})),
            )
            .send()
            .await
            .map_err(NodeCallError::transport)?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await);
        }
        resp.json().await.map_err(NodeCallError::transport)
    }

    /// Bearer token used on upstream WebSocket dials.
    pub fn token(&self) -> &str {
        &self.token
    }
}

/// Relay an upstream node response to the hub's client, dropping headers
/// that would act on the hub's origin.
fn relay_response(resp: reqwest::Response) -> Response {
    let status = resp.status();
    let mut headers = HeaderMap::new();
    for (name, value) in resp.headers() {
        if !STRIPPED_RESPONSE_HEADERS.contains(&name.as_str()) {
            headers.append(name.clone(), value.clone());
        }
    }
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static("sandbox"),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    let mut builder = Response::builder().status(status);
    *builder.headers_mut().unwrap() = headers;
    builder
        .body(Body::from_stream(resp.bytes_stream()))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// A failed node call: transport errors and structured [`NodeError`]s.
#[derive(Debug)]
pub enum NodeCallError {
    Transport(reqwest::Error),
    Remote { kind: String, message: String },
}

impl NodeCallError {
    fn transport(e: reqwest::Error) -> Self {
        Self::Transport(e)
    }

    async fn from_response(resp: reqwest::Response) -> Self {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        if let Ok(err) = serde_json::from_str::<NodeError>(&body) {
            return Self::Remote {
                kind: err.kind,
                message: err.message,
            };
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
            if let Some(msg) = v["error"].as_str() {
                return Self::Remote {
                    kind: status.as_u16().to_string(),
                    message: msg.to_string(),
                };
            }
        }
        Self::Remote {
            kind: status.as_u16().to_string(),
            message: if body.is_empty() {
                format!("node returned {status}")
            } else {
                body.chars().take(300).collect()
            },
        }
    }

    /// Map onto [`GitError`] using the remote `kind` tag.
    pub fn into_git_error(self) -> GitError {
        match self {
            Self::Transport(e) => GitError::Other(format!("node unreachable: {e}")),
            Self::Remote { kind, message } => match kind.as_str() {
                "not_enabled" => GitError::NotEnabled,
                "not_repo" => GitError::NotRepo,
                "timeout" => GitError::Timeout,
                _ => GitError::Other(message),
            },
        }
    }
}

impl std::fmt::Display for NodeCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(e) => write!(f, "node unreachable: {e}"),
            Self::Remote { message, .. } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for NodeCallError {}

/// Resolve the federation node row for a thread's project, if it is bound
/// to a satellite. Project-less threads are always local.
pub async fn node_for_thread(
    state: &crate::AppState,
    thread: &crate::db::ThreadRow,
) -> Option<FederationNodeRow> {
    let pid = thread.project_id?;
    let project = state.db.get_project(pid, thread.user_id).await.ok()??;
    node_for_project(state, &project).await
}

/// Resolve the federation node row a project is bound to.
pub async fn node_for_project(
    state: &crate::AppState,
    project: &crate::db::ProjectRow,
) -> Option<FederationNodeRow> {
    let node_id = project.node_id.as_deref()?;
    state.db.get_federation_node(node_id).await.ok()?
}

/// [`node_for_project`] with the dangerous case made an error: a project
/// bound to a node that was unpaired must not quietly fall back to the
/// local filesystem, where a same-spelled path is a different machine's
/// directory.
pub async fn bound_node(
    state: &crate::AppState,
    project: &crate::db::ProjectRow,
) -> anyhow::Result<Option<FederationNodeRow>> {
    if project.node_id.is_none() {
        return Ok(None);
    }
    match node_for_project(state, project).await {
        Some(n) => Ok(Some(n)),
        None => anyhow::bail!("project is bound to a node that is no longer paired"),
    }
}

/// [`bound_node`] for a thread's project.
pub async fn bound_node_for_thread(
    state: &crate::AppState,
    thread: &crate::db::ThreadRow,
) -> anyhow::Result<Option<FederationNodeRow>> {
    let Some(pid) = thread.project_id else {
        return Ok(None);
    };
    let Some(project) = state
        .db
        .get_project(pid, thread.user_id)
        .await
        .ok()
        .flatten()
    else {
        return Ok(None);
    };
    bound_node(state, &project).await
}

/// The git backend for a project: remote when node-bound, local otherwise.
/// Bound-but-missing nodes error rather than falling back to a same-spelled
/// local repository.
pub async fn git_backend_for_project(
    state: &crate::AppState,
    project: &crate::db::ProjectRow,
) -> anyhow::Result<GitBackend> {
    match bound_node(state, project).await {
        Ok(Some(node)) => {
            let client = NodeClient::for_node(state, &node)
                .ok_or_else(|| anyhow::anyhow!("node has no pairing credential"))?;
            Ok(GitBackend::Remote(RemoteGit::new(client)))
        }
        Ok(None) => Ok(GitBackend::Local(state.git.clone())),
        Err(e) => Err(e),
    }
}

/// `GitService`-shaped calls over the node's git endpoint.
#[derive(Clone)]
pub struct RemoteGit {
    client: NodeClient,
}

impl RemoteGit {
    pub fn new(client: NodeClient) -> Self {
        Self { client }
    }

    async fn call(
        &self,
        method: &str,
        repo: &Path,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, GitError> {
        let mut body = serde_json::Map::new();
        body.insert(
            "repo".into(),
            serde_json::Value::String(repo.to_string_lossy().to_string()),
        );
        if let serde_json::Value::Object(map) = args {
            body.extend(map);
        }
        let resp = self
            .client
            .authed(
                self.client
                    .client
                    .post(self.client.url(&format!("git/{method}")))
                    .json(&serde_json::Value::Object(body)),
            )
            .send()
            .await
            .map_err(|e| GitError::Other(format!("node unreachable: {e}")))?;
        if !resp.status().is_success() {
            return Err(NodeCallError::from_response(resp).await.into_git_error());
        }
        resp.json::<serde_json::Value>()
            .await
            .map_err(|e| GitError::Other(format!("invalid node response: {e}")))
    }
}

/// Local or remote git service, chosen per project/thread. Handlers call
/// the same method names either way.
#[derive(Clone)]
pub enum GitBackend {
    Local(Arc<crate::git::GitService>),
    Remote(RemoteGit),
}

macro_rules! git_methods {
    ($($name:ident ( $($arg:ident : $ty:ty),* ) -> $ret:ty => $method:literal { $($an:literal : $av:expr),* }),* $(,)?) => {
        impl GitBackend {
            $(
                pub async fn $name(&self, path: &Path, $($arg: $ty),*) -> Result<$ret, GitError> {
                    match self {
                        GitBackend::Local(git) => git.$name(path, $($arg),*).await,
                        GitBackend::Remote(remote) => {
                            let v = remote
                                .call($method, path, serde_json::json!({$($an: $av),*}))
                                .await?;
                            serde_json::from_value(v)
                                .map_err(|e| GitError::Other(format!("invalid node response: {e}")))
                        }
                    }
                }
            )*
        }
    };
}

git_methods! {
    repo_status(force: bool) -> RepoStatus => "repo_status" { "force": force },
    status(force: bool) -> serde_json::Value => "status" { "force": force },
    file_statuses() -> HashMap<String, String> => "file_statuses" {},
    changes(force: bool) -> ChangeList => "changes" { "force": force },
    change_diff(rel: &str, orig_path: Option<&str>, staged: bool, force: bool) -> Option<crate::providers::FileDiff> => "change_diff" { "path": rel, "orig_path": orig_path, "staged": staged, "force": force },
    discard(paths: &[String], staged: bool) -> () => "discard" { "paths": paths, "staged": staged },
    log(limit: usize, offset: usize, force: bool) -> CommitPage => "log" { "limit": limit, "offset": offset, "force": force },
    stage(paths: &[String], all: bool) -> () => "stage" { "paths": paths, "all": all },
    unstage(paths: &[String], all: bool) -> () => "unstage" { "paths": paths, "all": all },
    commit(message: &str, all: bool) -> CommitResult => "commit" { "message": message, "all": all },
    branches(query: Option<&str>, limit: Option<usize>, force: bool) -> Vec<Branch> => "branches" { "query": query, "limit": limit, "force": force },
    create_branch(name: &str, base: Option<&str>, switch: bool) -> String => "create_branch" { "name": name, "base": base, "switch": switch },
    checkout(ref_name: &str, track: bool) -> String => "checkout" { "ref_name": ref_name, "track": track },
    pull() -> () => "pull" {},
    pull_branch(name: &str) -> () => "pull_branch" { "name": name },
    push() -> () => "push" {},
    worktrees(force: bool) -> Vec<Worktree> => "worktrees" { "force": force },
    create_worktree(name: &str, base: &str, new_branch: bool) -> Worktree => "create_worktree" { "name": name, "base": base, "new_branch": new_branch },
    remove_worktree(worktree_path: &Path) -> () => "remove_worktree" { "worktree_path": worktree_path },
    prune_worktrees() -> () => "prune_worktrees" {},
    delete_branch(name: &str) -> () => "delete_branch" { "name": name },
    remote_url() -> String => "remote_url" {},
}

impl GitBackend {
    /// `create_worktree_at` takes a `PathBuf` arg, which does not fit the
    /// value-only macro shape; it lives outside.
    pub async fn create_worktree_at(
        &self,
        path: &Path,
        branch_name: &str,
        base: &str,
        worktree_path: &Path,
        new_branch: bool,
    ) -> Result<Worktree, GitError> {
        match self {
            GitBackend::Local(git) => {
                git.create_worktree_at(path, branch_name, base, worktree_path, new_branch)
                    .await
            }
            GitBackend::Remote(remote) => {
                let v = remote
                    .call(
                        "create_worktree_at",
                        path,
                        serde_json::json!({
                            "branch": branch_name,
                            "base": base,
                            "worktree_path": worktree_path,
                            "new_branch": new_branch,
                        }),
                    )
                    .await?;
                serde_json::from_value(v)
                    .map_err(|e| GitError::Other(format!("invalid node response: {e}")))
            }
        }
    }
}

/// Response builders for node forwarding failures.
pub fn node_bad_gateway(msg: impl Into<String>) -> Response {
    (
        StatusCode::BAD_GATEWAY,
        Json(crate::api::ApiError::new(msg.into())),
    )
        .into_response()
}
