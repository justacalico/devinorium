//! Codex provider: drives `codex app-server --stdio`, the JSON-RPC transport
//! built into the Codex CLI.
//!
//! One child process is spawned per prompt turn — matching the ACP provider's
//! model. New conversations open with `thread/start`, follow-ups reopen the
//! persisted thread with `thread/resume` (`excludeTurns`, so no history is
//! replayed), and each message runs as a `turn/start` whose notifications
//! stream back until `turn/completed`.

use std::path::Path;
use std::sync::atomic::Ordering;

use async_trait::async_trait;
use serde_json::{json, Value};

use super::approvals::{handle_server_request, thread_config, ServerRequestResponse};
use super::events::TurnTranslator;
use super::rpc::{AppServer, ServerEvent};
use super::wire::{ThreadResponse, Turn, TurnResponse};
use crate::providers::acp::provider::ensure_writable_attachment_dir;
use crate::providers::{
    apply_interaction_mode_prefix, collect_text, collect_thinking, title_from_prompt, MessagePart,
    ModelInfo, Provider, SendOptions, SendRequest, SendResponse, StartRequest, StartResponse,
    UsageSnapshot,
};

/// Provider id used in the registry, user settings, and thread rows.
pub const PROVIDER_ID: &str = "codex";

pub struct CodexProvider {
    bin: String,
    default_model: String,
}

impl CodexProvider {
    pub fn new(bin: String, default_model: String) -> Self {
        Self { bin, default_model }
    }
}

/// Run the `initialize` handshake and send the `initialized` notification.
pub(crate) async fn handshake(server: &AppServer) -> anyhow::Result<()> {
    server
        .request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "devinorium",
                    "version": env!("CARGO_PKG_VERSION"),
                }
            }),
        )
        .await?;
    server.notify("initialized").await?;
    Ok(())
}

struct PromptResult {
    session_id: String,
    parts: Vec<MessagePart>,
    usage: Option<UsageSnapshot>,
}

impl CodexProvider {
    /// Pick the model for a new turn: the request's model, the configured
    /// default, or nothing (codex's own configured default). Models the
    /// installed CLI does not advertise are dropped with a warning so a stale
    /// default like `glm-5-2` cannot poison codex threads.
    async fn resolve_model(&self, options: &SendOptions) -> Option<String> {
        let requested = {
            let m = options.model.trim();
            if m.is_empty() {
                self.default_model.trim().to_string()
            } else {
                m.to_string()
            }
        };
        if requested.is_empty() || requested == "default" {
            return None;
        }

        match super::models::known_model_ids(&self.bin, &options.working_dir).await {
            // The catalog loaded: only forward models codex knows.
            Some(known) if !known.contains(&requested) => {
                tracing::warn!(
                    model = %requested,
                    "model not in codex model list, falling back to the CLI default"
                );
                None
            }
            Some(_) => Some(requested),
            // The catalog could not be fetched: trust the configured value.
            None => Some(requested),
        }
    }

    /// Open or reopen a codex thread. `thread/resume` may fail when the
    /// stored rollout is gone; fall back to a fresh thread in that case.
    async fn open_thread(
        &self,
        server: &AppServer,
        options: &SendOptions,
        session: Option<&str>,
        model: Option<&str>,
    ) -> anyhow::Result<String> {
        let config = thread_config(&options.permission_mode);
        let cwd = options.working_dir.to_string_lossy();
        let mut params = json!({
            "cwd": cwd,
            "approvalPolicy": config.approval_policy,
            "sandbox": config.sandbox,
            "approvalsReviewer": config.approvals_reviewer,
        });
        if let Some(model) = model {
            params["model"] = json!(model);
        }

        if let Some(thread_id) = session {
            let mut resume = params.clone();
            resume["threadId"] = json!(thread_id);
            resume["excludeTurns"] = json!(true);
            match server.request("thread/resume", resume).await {
                Ok(result) => {
                    let resp: ThreadResponse = serde_json::from_value(result)?;
                    return Ok(resp.thread.id);
                }
                Err(e) => {
                    tracing::warn!(
                        thread_id = %thread_id,
                        error = %e,
                        "codex thread resume failed; starting a fresh thread"
                    );
                }
            }
        }

        let result = server.request("thread/start", params).await?;
        let resp: ThreadResponse = serde_json::from_value(result)?;
        Ok(resp.thread.id)
    }

    /// Build the `turn/start` input items: the prompt text (with the mode
    /// prefix), file references for non-image attachments, and `localImage`
    /// items for images.
    async fn build_input(&self, options: &SendOptions, prompt: &str) -> anyhow::Result<Vec<Value>> {
        let prompt = apply_interaction_mode_prefix(prompt.to_string(), &options.interaction_mode);
        let mut input = vec![json!({ "type": "text", "text": prompt })];

        if options.attachments.is_empty() {
            return Ok(input);
        }
        let att_dir = ensure_writable_attachment_dir(&options.working_dir).await?;
        for (i, att) in options.attachments.iter().enumerate() {
            let name = format!("{}_{}", i, sanitize_filename(&att.filename));
            let path = att_dir.join(&name);
            tokio::fs::write(&path, &att.data).await?;
            if att.mime.starts_with("image/") && !att.mime.ends_with("svg+xml") {
                input.push(json!({ "type": "localImage", "path": path.to_string_lossy() }));
            } else {
                input.push(json!({
                    "type": "text",
                    "text": format!(
                        "\n\n[Attachment {}: {} ({} bytes)]\n@{}\n",
                        i, att.filename, att.data.len(), path.display()
                    ),
                }));
            }
        }
        Ok(input)
    }

    async fn run_prompt(
        &self,
        options: &SendOptions,
        session: Option<&str>,
        prompt: String,
    ) -> anyhow::Result<PromptResult> {
        let server = AppServer::spawn(&self.bin, &options.working_dir).await?;
        handshake(&server).await?;

        let model = self.resolve_model(options).await;
        let thread_id = self
            .open_thread(&server, options, session, model.as_deref())
            .await?;

        if session != Some(thread_id.as_str()) {
            if let Some(ref cb) = options.session_callback {
                cb(thread_id.clone()).await;
            }
        }

        let input = self.build_input(options, &prompt).await?;
        let config = thread_config(&options.permission_mode);
        let mut turn_params = json!({
            "threadId": thread_id,
            "input": input,
            "approvalPolicy": config.approval_policy,
            "approvalsReviewer": config.approvals_reviewer,
            "sandboxPolicy": config.sandbox_policy,
        });
        if let Some(model) = &model {
            turn_params["model"] = json!(model);
        }

        let result = server.request("turn/start", turn_params).await?;
        let turn: Turn = serde_json::from_value::<TurnResponse>(result)?.turn;
        let turn_id = turn.id;

        // When the user cancels, interrupt the turn so the thread keeps its
        // context for follow-up messages.
        if let Some(flag) = options.cancel_signal.clone() {
            let server = server.clone();
            let (tid, turn_id) = (thread_id.clone(), turn_id.clone());
            tokio::spawn(async move {
                while !flag.load(Ordering::SeqCst) {
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
                // Fire and forget: the reply is irrelevant and awaiting it
                // would keep the child alive for the request timeout.
                let _ = server
                    .send_untracked(
                        "turn/interrupt",
                        json!({ "threadId": tid, "turnId": turn_id }),
                    )
                    .await;
            });
        }

        let mut translator = TurnTranslator::new();
        let mut parts = Vec::new();
        let part_callback = options.part_callback.clone();
        // `thread/start` returns a provisional id; codex re-announces the
        // thread once it is persisted (rollout id) via `thread/started`. Track
        // the latest id so follow-up `thread/resume` calls hit the rollout.
        let mut thread_id = thread_id;

        let completed_turn = loop {
            match server.next_event().await {
                ServerEvent::Notification { method, params } => {
                    // Ignore stale notifications from other turns (e.g. a
                    // replayed item after resume).
                    if let Some(tid) = params.get("turnId").and_then(Value::as_str) {
                        if tid != turn_id {
                            continue;
                        }
                    }
                    // Any notification carrying a threadId may reveal the
                    // persisted rollout id once the first turn runs.
                    if let Some(tid) = params
                        .get("threadId")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                    {
                        if tid != thread_id {
                            thread_id = tid.to_string();
                            if let Some(ref cb) = options.session_callback {
                                cb(thread_id.clone()).await;
                            }
                        }
                    }
                    match method.as_str() {
                        "thread/started" => {
                            if let Some(t) = params.get("thread") {
                                let id = t
                                    .get("sessionId")
                                    .or_else(|| t.get("id"))
                                    .and_then(Value::as_str)
                                    .filter(|s| !s.is_empty());
                                if let Some(id) = id {
                                    if id != thread_id {
                                        thread_id = id.to_string();
                                        if let Some(ref cb) = options.session_callback {
                                            cb(thread_id.clone()).await;
                                        }
                                    }
                                }
                            }
                        }
                        "turn/completed" => {
                            let turn: Option<Turn> = params
                                .get("turn")
                                .and_then(|t| serde_json::from_value(t.clone()).ok());
                            match turn {
                                Some(t) if t.id == turn_id => break t,
                                _ => continue,
                            }
                        }
                        "error" => {
                            tracing::warn!(params = %params, "codex app-server error notification");
                        }
                        _ => {
                            if let Some(event) = translator.apply(&method, &params, &mut parts) {
                                if let Some(cb) = &part_callback {
                                    cb(event);
                                }
                            }
                        }
                    }
                }
                ServerEvent::Request { id, method, params } => {
                    let response = handle_server_request(
                        &method,
                        &params,
                        options.permission_callback.as_ref(),
                        options.ask_callback.as_ref(),
                    )
                    .await;
                    let write = match response {
                        ServerRequestResponse::Result(v) => server.respond(id, v).await,
                        ServerRequestResponse::MethodNotFound => {
                            server.respond_error(id, "unsupported request").await
                        }
                    };
                    if let Err(e) = write {
                        tracing::warn!(method = %method, error = %e, "failed to answer codex request");
                    }
                }
                ServerEvent::Closed => {
                    anyhow::bail!("codex app-server exited before the turn completed")
                }
            }
        };

        // Release the thread writer so a later app-server process can resume
        // it — the lock is not dropped when the child exits.
        let _ = server
            .request("thread/unsubscribe", json!({ "threadId": thread_id }))
            .await;

        if completed_turn.status == "failed" {
            let message = completed_turn
                .error
                .map(|e| e.message)
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "codex turn failed".to_string());
            anyhow::bail!(message);
        }

        Ok(PromptResult {
            session_id: thread_id,
            parts,
            usage: translator.usage,
        })
    }
}

fn sanitize_filename(name: &str) -> String {
    crate::providers::acp::content::sanitize(name)
}

#[async_trait]
impl Provider for CodexProvider {
    fn id(&self) -> &str {
        PROVIDER_ID
    }

    fn name(&self) -> &str {
        "Codex CLI"
    }

    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        match super::models::fetch_models(&self.bin, Path::new(".")).await {
            Ok(models) if !models.is_empty() => Ok(models),
            Ok(_) | Err(_) => Ok(super::models::static_models()),
        }
    }

    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let title = title_from_prompt(&req.prompt);
        let result = self.run_prompt(&req.options, None, req.prompt).await?;
        Ok(StartResponse {
            session_id: result.session_id,
            title,
            reply: collect_text(&result.parts),
            thinking: collect_thinking(&result.parts),
            parts: result.parts,
            usage: result.usage,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let result = self
            .run_prompt(&req.options, Some(&req.session_id), req.prompt)
            .await?;
        Ok(SendResponse {
            reply: collect_text(&result.parts),
            thinking: collect_thinking(&result.parts),
            parts: result.parts,
            usage: result.usage,
        })
    }

    async fn export(
        &self,
        _session_id: &str,
        _working_dir: &Path,
    ) -> anyhow::Result<serde_json::Value> {
        // Codex sessions live under ~/.codex; there is no export RPC.
        Ok(json!({}))
    }

    async fn health_check(&self) -> anyhow::Result<()> {
        if which::which(&self.bin).is_err() {
            anyhow::bail!("provider command not found: {}", self.bin);
        }
        let cwd = std::env::temp_dir();
        let server = AppServer::spawn(&self.bin, &cwd).await?;
        tokio::time::timeout(std::time::Duration::from_secs(15), handshake(&server))
            .await
            .map_err(|_| anyhow::anyhow!("codex app-server handshake timed out"))??;
        Ok(())
    }

    async fn version_info(&self) -> crate::providers::ProviderVersion {
        super::version::check_version(&self.bin).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::SendOptions;
    use std::path::PathBuf;
    use std::sync::Arc;

    /// A fake `codex` binary that implements just enough of the app-server
    /// protocol for a full prompt round trip.
    #[cfg(unix)]
    fn fake_codex(dir: &Path) -> PathBuf {
        let path = dir.join("codex");
        std::fs::write(
            &path,
            r#"#!/bin/sh
id_of() { printf '%s' "$1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"userAgent":"fake"}}\n' "$id"
      ;;
    *'"method":"thread/start"'*|*'"method":"thread/resume"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"thread":{"id":"th-1","cliVersion":"0","createdAt":0,"cwd":"/tmp","ephemeral":false,"modelProvider":"openai","preview":"","projectId":"","sessionId":"","source":"","status":"","turns":[],"updatedAt":0}}}\n' "$id"
      ;;
    *'"method":"turn/start"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"turn":{"id":"tu-1","items":[],"status":"inProgress"}}}\n' "$id"
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"th-1","sessionId":"roll-9"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"roll-9","turnId":"tu-1","itemId":"m1","delta":"Hel"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"th-1","turnId":"tu-1","itemId":"m1","delta":"lo"}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"th-1","turnId":"tu-1","startedAtMs":0,"item":{"id":"c1","type":"commandExecution","command":"echo hi","commandActions":[],"cwd":"/tmp","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"th-1","turnId":"tu-1","completedAtMs":1,"item":{"id":"c1","type":"commandExecution","command":"echo hi","commandActions":[],"cwd":"/tmp","status":"completed","aggregatedOutput":"hi\n","exitCode":0}}}'
      printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"th-1","turnId":"tu-1","tokenUsage":{"total":{"inputTokens":10,"outputTokens":4,"reasoningOutputTokens":1,"cachedInputTokens":0,"totalTokens":14},"last":{"inputTokens":10,"outputTokens":4,"reasoningOutputTokens":1,"cachedInputTokens":0,"totalTokens":14}}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"roll-9","turn":{"id":"tu-1","items":[],"status":"completed"}}}'
      ;;
    *'"method":"thread/unsubscribe"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"status":"unsubscribed"}}\n' "$id"
      ;;
    *'"method":"model/list"'*)
      id=$(id_of "$line")
      printf '{"id":%s,"result":{"data":[{"id":"gpt-test","model":"gpt-test","displayName":"GPT Test","description":"d","hidden":false,"isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[]}]}}\n' "$id"
      ;;
  esac
done
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn options(dir: &Path) -> SendOptions {
        SendOptions {
            model: "gpt-test".into(),
            working_dir: dir.to_path_buf(),
            permission_mode: "normal".into(),
            permissions: None,
            attachments: vec![],
            permission_callback: None,
            ask_callback: None,
            part_callback: None,
            session_callback: None,
            interaction_mode: "code".into(),
            cancel_signal: None,
        }
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn start_runs_a_full_turn() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let provider = CodexProvider::new(bin.to_string_lossy().into(), String::new());

        let resp = provider
            .start(StartRequest {
                prompt: "hi".into(),
                options: options(dir.path()),
            })
            .await
            .unwrap();

        // The durable rollout id is announced mid-turn via `thread/started`.
        assert_eq!(resp.session_id, "roll-9");
        assert_eq!(resp.reply, "Hello");
        assert_eq!(resp.usage.unwrap().total_tokens, 14);
        assert!(
            resp.parts
                .iter()
                .any(|p| matches!(p, MessagePart::ToolCall { payload } if payload.command.as_deref() == Some("echo hi")))
        );
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn send_resumes_the_thread() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let provider = CodexProvider::new(bin.to_string_lossy().into(), String::new());

        let resp = provider
            .send(SendRequest {
                session_id: "th-1".into(),
                prompt: "again".into(),
                options: options(dir.path()),
            })
            .await
            .unwrap();

        assert_eq!(resp.reply, "Hello");
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn unknown_model_falls_back_to_cli_default() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let provider = CodexProvider::new(bin.to_string_lossy().into(), String::new());
        let mut opts = options(dir.path());
        opts.model = "glm-5-2".into();

        // resolve_model should drop the unknown model instead of failing.
        assert_eq!(provider.resolve_model(&opts).await, None);
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn known_model_is_kept() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let provider = CodexProvider::new(bin.to_string_lossy().into(), String::new());
        let opts = options(dir.path());
        assert_eq!(
            provider.resolve_model(&opts).await.as_deref(),
            Some("gpt-test")
        );
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn streams_part_events_and_reports_session() {
        let dir = tempfile::tempdir().unwrap();
        let bin = fake_codex(dir.path());
        let provider = CodexProvider::new(bin.to_string_lossy().into(), String::new());
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sessions = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));

        let mut opts = options(dir.path());
        {
            let events = events.clone();
            opts.part_callback = Some(Arc::new(move |ev| {
                events.lock().unwrap().push(match ev {
                    crate::providers::PartEvent::New(p) => ("new", format!("{p:?}")),
                    crate::providers::PartEvent::Update(p) => ("update", format!("{p:?}")),
                });
            }));
        }
        {
            let sessions = sessions.clone();
            opts.session_callback = Some(Arc::new(move |sid| {
                let sessions = sessions.clone();
                Box::pin(async move {
                    sessions.lock().unwrap().push(sid);
                })
            }));
        }

        provider
            .start(StartRequest {
                prompt: "hi".into(),
                options: opts,
            })
            .await
            .unwrap();

        let events = events.lock().unwrap();
        // Text deltas arrive as New chunk events (the SSE layer appends each).
        assert!(events.iter().filter(|(k, _)| *k == "new").count() >= 2);
        assert!(events
            .iter()
            .any(|(_, p)| p.contains("ToolCall") && p.contains("echo hi")));
        // The persisted rollout id is reported through the session callback.
        assert!(sessions.lock().unwrap().iter().any(|id| id == "roll-9"));
    }
}
