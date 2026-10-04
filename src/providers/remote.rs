//! Remote provider: runs the provider on a paired satellite.
//!
//! [`RemoteProvider`] implements the same [`Provider`] trait as the local
//! providers, so the whole run pipeline (parts streaming, permission and
//! ask prompts, usage accounting, stop) works unchanged — only the process
//! executing the agent lives on another machine. The satellite holds no
//! state: each call ships the prompt, options and provider identity over
//! `POST /api/node/run`, reads back a [`NodeEvent`] SSE stream, and answers
//! interactive requests through `POST /api/node/callback`.

use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::Context;
use async_trait::async_trait;
use futures::StreamExt;

use crate::node::{
    CallbackOutcome, NodeEvent, RunRequest, WireAttachment, WireProvider, WireSendOptions,
};
use crate::node_client::{NodeCallError, NodeClient};

use super::{
    Attachment, ModelInfo, Provider, ProviderVersion, SendOptions, SendRequest, SendResponse,
    StartRequest, StartResponse,
};

/// A provider whose backing CLI runs on a satellite node.
pub struct RemoteProvider {
    client: NodeClient,
    provider_id: String,
    command: String,
    default_model: String,
}

impl RemoteProvider {
    pub fn new(client: NodeClient, provider_id: &str, command: &str, default_model: &str) -> Self {
        Self {
            client,
            provider_id: provider_id.to_string(),
            command: command.to_string(),
            default_model: default_model.to_string(),
        }
    }

    fn wire_options(options: &SendOptions, expand_skills: bool) -> WireSendOptions {
        use base64::Engine;
        WireSendOptions {
            model: options.model.clone(),
            reasoning_effort: options.reasoning_effort.clone(),
            working_dir: options.working_dir.clone(),
            permission_mode: options.permission_mode.clone(),
            permissions: options.permissions.clone(),
            attachments: options
                .attachments
                .iter()
                .map(|a: &Attachment| WireAttachment {
                    filename: a.filename.clone(),
                    mime: a.mime.clone(),
                    data_b64: base64::engine::general_purpose::STANDARD.encode(&a.data),
                })
                .collect(),
            interaction_mode: options.interaction_mode.clone(),
            max_output_tokens: options.max_output_tokens,
            mcp_servers: options.mcp_servers.clone(),
            expand_skills,
        }
    }

    /// Run one provider turn on the satellite, streaming events back through
    /// the caller's callbacks. Returns the final [`crate::node::RunOutcome`].
    async fn run_turn(
        &self,
        prompt: &str,
        session_id: Option<String>,
        options: &SendOptions,
    ) -> anyhow::Result<crate::node::RunOutcome> {
        let run_id = uuid::Uuid::new_v4().to_string();
        let request = RunRequest {
            run_id: run_id.clone(),
            session_id,
            prompt: prompt.to_string(),
            provider: WireProvider {
                id: self.provider_id.clone(),
                command: self.command.clone(),
                default_model: self.default_model.clone(),
            },
            // Devin resolves slash commands itself; every other provider
            // gets the satellite-side skill expansion the hub would have
            // applied locally.
            options: Self::wire_options(
                options,
                self.provider_id != crate::providers::acp::AgentKind::Devin.id(),
            ),
        };

        let resp = self
            .client
            .run(&request)
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        // Watch the caller's cancel flag; the satellite turns it into a
        // graceful provider cancel so the session keeps its context.
        let cancel_flag = options.cancel_signal.clone();
        let cancel_watcher = cancel_flag.clone().map(|flag| {
            let client = self.client.clone();
            let run_id = run_id.clone();
            tokio::spawn(async move {
                loop {
                    if flag.load(Ordering::SeqCst) {
                        let _ = client.cancel_run(&run_id).await;
                        return;
                    }
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            })
        });
        let result = self.consume(resp, options).await;
        if let Some(w) = cancel_watcher {
            w.abort();
        }
        // A dead connection without an explicit cancel still leaves the
        // satellite run dangling; best-effort cancel on early failures.
        if result.is_err() {
            let _ = self.client.cancel_run(&run_id).await;
        }
        result
    }

    /// Read the node event stream, dispatching interactive callbacks and
    /// returning the `done` outcome.
    async fn consume(
        &self,
        resp: reqwest::Response,
        options: &SendOptions,
    ) -> anyhow::Result<crate::node::RunOutcome> {
        let mut stream = resp.bytes_stream();
        let mut buf = String::new();
        let mut last_session: Option<String> = None;
        loop {
            let Some(chunk) = stream.next().await else {
                anyhow::bail!("node stream ended without a result");
            };
            let chunk = chunk.context("node stream error")?;
            buf.push_str(&String::from_utf8_lossy(&chunk));
            while let Some(ev) = take_sse_event(&mut buf) {
                match self.handle_event(ev, options).await? {
                    EventEffect::Done(mut outcome) => {
                        if outcome.session_id.is_none() {
                            outcome.session_id = last_session;
                        }
                        return Ok(*outcome);
                    }
                    EventEffect::Session(id) => last_session = Some(id),
                    EventEffect::Continue => {}
                }
            }
        }
    }

    async fn handle_event(
        &self,
        ev: NodeEvent,
        options: &SendOptions,
    ) -> anyhow::Result<EventEffect> {
        match ev {
            NodeEvent::Session { session_id } => {
                if let Some(cb) = &options.session_callback {
                    cb(session_id.clone()).await;
                }
                Ok(EventEffect::Session(session_id))
            }
            NodeEvent::Part { part, update } => {
                if let Some(cb) = &options.part_callback {
                    let ev = if update {
                        crate::providers::PartEvent::Update(part)
                    } else {
                        crate::providers::PartEvent::New(part)
                    };
                    cb(ev);
                }
                Ok(EventEffect::Continue)
            }
            NodeEvent::Permission {
                request_id,
                request,
            } => {
                let outcome = match &options.permission_callback {
                    Some(cb) => match cb(request).await {
                        crate::providers::PermissionOutcome::Allow { option_id } => {
                            CallbackOutcome::Permission { option_id }
                        }
                        crate::providers::PermissionOutcome::Cancel => {
                            CallbackOutcome::PermissionCancel
                        }
                    },
                    None => CallbackOutcome::PermissionCancel,
                };
                if let Err(e) = self.client.callback(&request_id, &outcome).await {
                    tracing::warn!(error = %e, "failed to deliver permission answer to node");
                }
                Ok(EventEffect::Continue)
            }
            NodeEvent::Ask {
                request_id,
                request,
            } => {
                let outcome = match &options.ask_callback {
                    Some(cb) => match cb(request).await {
                        crate::providers::AskOutcome::Answers(answers) => {
                            CallbackOutcome::Ask { answers }
                        }
                        crate::providers::AskOutcome::Cancel => CallbackOutcome::AskCancel,
                    },
                    None => CallbackOutcome::AskCancel,
                };
                if let Err(e) = self.client.callback(&request_id, &outcome).await {
                    tracing::warn!(error = %e, "failed to deliver ask answer to node");
                }
                Ok(EventEffect::Continue)
            }
            NodeEvent::Done { outcome } => Ok(EventEffect::Done(outcome)),
            NodeEvent::Error { message } => anyhow::bail!("{message}"),
        }
    }
}

enum EventEffect {
    Continue,
    Session(String),
    Done(Box<crate::node::RunOutcome>),
}

/// Pop one complete `data:` SSE payload off the buffer. Satellite events
/// are single-line JSON, so an event ends at a blank line. Comment blocks
/// (keep-alives) and non-data lines are skipped rather than ending the
/// stream — returning `None` must mean "no complete block yet", never
/// "the next block was not an event", or a keep-alive flushed right before
/// `done` would swallow the result.
fn take_sse_event(buf: &mut String) -> Option<NodeEvent> {
    loop {
        let end = buf.find("\n\n")?;
        let raw = buf[..end].to_string();
        buf.drain(..end + 2);
        for line in raw.lines() {
            if let Some(data) = line.strip_prefix("data:") {
                let data = data.trim_start();
                // An unparseable payload is dropped, not treated as the end
                // of buffered events: one bad event must not wedge the run.
                if let Ok(ev) = serde_json::from_str::<NodeEvent>(data) {
                    return Some(ev);
                }
            }
        }
    }
}

#[async_trait]
impl Provider for RemoteProvider {
    fn id(&self) -> &str {
        // Leak-free: the id lives in the struct, but `Provider::id` needs
        // &'static — return a static for the known provider ids.
        match self.provider_id.as_str() {
            "devin-cli" => "devin-cli",
            "opencode" => "opencode",
            "codex" => "codex",
            "grok" => "grok",
            _ => "remote",
        }
    }

    fn name(&self) -> &str {
        crate::providers::provider_name(&self.provider_id).unwrap_or("Remote")
    }

    async fn list_models(&self) -> anyhow::Result<Vec<ModelInfo>> {
        self.client
            .provider_models(&self.provider_id, &self.command, &self.default_model)
            .await
            .map_err(|e: NodeCallError| anyhow::anyhow!("{e}"))
    }

    async fn start(&self, req: StartRequest) -> anyhow::Result<StartResponse> {
        let outcome = self.run_turn(&req.prompt, None, &req.options).await?;
        Ok(StartResponse {
            session_id: outcome.session_id.unwrap_or_default(),
            reply: outcome.reply,
            thinking: outcome.thinking,
            parts: outcome.parts,
            title: outcome.title.unwrap_or_else(|| "New thread".into()),
            usage: outcome.usage,
        })
    }

    async fn send(&self, req: SendRequest) -> anyhow::Result<SendResponse> {
        let outcome = self
            .run_turn(&req.prompt, Some(req.session_id), &req.options)
            .await?;
        Ok(SendResponse {
            reply: outcome.reply,
            thinking: outcome.thinking,
            parts: outcome.parts,
            usage: outcome.usage,
        })
    }

    async fn health_check(&self) -> anyhow::Result<()> {
        self.client
            .provider_health(&self.provider_id, &self.command, &self.default_model)
            .await
            .map_err(|e: NodeCallError| anyhow::anyhow!("{e}"))
    }

    async fn version_info(&self) -> ProviderVersion {
        ProviderVersion::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_parser_skips_keepalive_blocks() {
        // A keep-alive comment flushed in the same chunk as `done` must not
        // swallow the terminal event.
        let mut buf = String::from(
            ": keep-alive\n\ndata: {\"kind\":\"done\",\"outcome\":{\"session_id\":\"s\",\"reply\":\"ok\",\"thinking\":\"\",\"parts\":[]}}\n\n",
        );
        let ev = take_sse_event(&mut buf).expect("done event survives the keep-alive");
        assert!(matches!(ev, NodeEvent::Done { .. }));
    }

    #[test]
    fn sse_parser_waits_for_incomplete_block() {
        let mut buf = String::from("data: {\"kind\":\"error\"");
        assert!(take_sse_event(&mut buf).is_none());
        buf.push_str(",\"message\":\"boom\"}\n\n");
        assert!(matches!(
            take_sse_event(&mut buf),
            Some(NodeEvent::Error { .. })
        ));
    }
}
