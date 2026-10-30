//! MCP server over stdio.
//!
//! Speaks the MCP wire format (newline-delimited JSON-RPC 2.0 on
//! stdin/stdout) and exposes the browser tools to whichever agent spawned
//! us. The browser engine is launched lazily on the first `tools/call` so
//! `initialize`/`tools/list` never depend on a Chromium binary existing.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::action;
use super::engine::{ChromiumEngine, Engine};
use super::tools;

const PROTOCOL_VERSION: &str = "2025-06-18";

/// Reject absurd single messages; MCP requests are small JSON-RPC bodies.
const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

type EngineFactory = Arc<
    dyn Fn() -> Pin<Box<dyn Future<Output = Result<Box<dyn Engine>, String>> + Send>> + Send + Sync,
>;

/// Entry point for `devinorium browser-mcp`.
pub async fn run_stdio() -> anyhow::Result<()> {
    let factory: EngineFactory = Arc::new(|| {
        Box::pin(async {
            ChromiumEngine::launch()
                .await
                .map(|e| Box::new(e) as Box<dyn Engine>)
        })
    });
    let stdin = BufReader::new(tokio::io::stdin());
    let stdout = tokio::io::stdout();
    tokio::select! {
        r = serve(stdin, stdout, factory) => r,
        // Agents terminate stdio MCP servers with SIGTERM/SIGKILL. Catching
        // it drops the slot, which kills chromium via kill_on_drop instead
        // of leaving an orphaned browser.
        _ = shutdown_signal() => Ok(()),
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        if let Ok(mut term) = signal(SignalKind::terminate()) {
            term.recv().await;
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}

/// Lazily-created engine. A dead browser is dropped and relaunched on the
/// next call; a failed launch does not stick, so a binary installed later
/// or a transient spawn failure heals itself.
struct EngineSlot {
    engine: Option<Box<dyn Engine>>,
}

impl EngineSlot {
    async fn get(&mut self, factory: &EngineFactory) -> Result<&mut dyn Engine, String> {
        if self.engine.as_mut().is_some_and(|e| !e.alive()) {
            self.engine = None;
        }
        if self.engine.is_none() {
            self.engine = Some(factory().await?);
        }
        Ok(self.engine.as_deref_mut().unwrap())
    }
}

fn rpc_error(id: &Value, code: i64, message: impl Into<String>) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {"code": code, "message": message.into()},
    })
}

fn rpc_ok(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn tool_result(result: Result<Vec<super::ToolContent>, String>) -> Value {
    match result {
        Ok(content) => json!({
            "content": content.iter().map(|c| c.to_json()).collect::<Vec<_>>(),
        }),
        Err(e) => json!({
            "content": [{"type": "text", "text": e}],
            "isError": true,
        }),
    }
}

/// Handle one request; `None` means nothing should be written back
/// (notifications and the `initialized` handshake).
async fn handle(msg: &Value, slot: &mut EngineSlot, factory: &EngineFactory) -> Option<Value> {
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    let is_notification = msg.get("id").is_none();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(Value::Null);

    if is_notification {
        return None;
    }

    Some(match method {
        "initialize" => rpc_ok(
            &id,
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {
                    "name": "devinorium-browser",
                    "version": env!("CARGO_PKG_VERSION"),
                },
            }),
        ),
        "ping" => rpc_ok(&id, json!({})),
        "tools/list" => rpc_ok(&id, json!({"tools": tools::tools()})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(Value::Null);
            match action::parse(name, &args) {
                Err(e) => rpc_error(&id, -32602, e),
                Ok(action) => {
                    let result = match slot.get(factory).await {
                        Err(e) => Err(e),
                        Ok(engine) => engine.perform(&action).await,
                    };
                    rpc_ok(&id, tool_result(result))
                }
            }
        }
        "resources/list" => rpc_ok(&id, json!({"resources": []})),
        "prompts/list" => rpc_ok(&id, json!({"prompts": []})),
        _ => rpc_error(&id, -32601, format!("method not found: {method}")),
    })
}

/// The read/eval/write loop. Returns when stdin closes (the agent dropped
/// the stdio pipe) or a hard IO error occurs.
async fn serve<R, W>(reader: R, mut writer: W, factory: EngineFactory) -> anyhow::Result<()>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut slot = EngineSlot { engine: None };
    let mut lines = reader.lines();
    while let Some(line) = lines.next_line().await? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line.len() > MAX_LINE_BYTES {
            let resp = rpc_error(&Value::Null, -32700, "message too large");
            let mut out = serde_json::to_vec(&resp)?;
            out.push(b'\n');
            writer.write_all(&out).await?;
            writer.flush().await?;
            continue;
        }
        let response = match serde_json::from_str::<Value>(line) {
            Err(_) => Some(rpc_error(&Value::Null, -32700, "parse error")),
            Ok(msg) => handle(&msg, &mut slot, &factory).await,
        };
        if let Some(resp) = response {
            let mut out = serde_json::to_vec(&resp)?;
            out.push(b'\n');
            writer.write_all(&out).await?;
            writer.flush().await?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser::engine::test_support::FakeEngine;
    use crate::browser::ToolContent;
    use std::io::Cursor;

    fn fake_factory(
        results: Vec<Result<Vec<ToolContent>, String>>,
    ) -> (EngineFactory, Arc<Mutex<Vec<String>>>) {
        use std::sync::Mutex;
        let calls = Arc::new(Mutex::new(Vec::new()));
        let calls2 = calls.clone();
        let results = Arc::new(Mutex::new(results));
        let factory: EngineFactory = Arc::new(move || {
            let results = results.clone();
            let calls = calls2.clone();
            Box::pin(async move {
                calls.lock().unwrap().push("launch".to_string());
                Ok(Box::new(FakeEngine::new(results.lock().unwrap().clone())) as Box<dyn Engine>)
            })
        });
        (factory, calls)
    }

    use std::sync::Mutex;

    async fn run(script: &str, factory: EngineFactory) -> Vec<Value> {
        let reader = Cursor::new(script.as_bytes().to_vec());
        let mut writer: Vec<u8> = Vec::new();
        serve(reader, &mut writer, factory).await.unwrap();
        String::from_utf8(writer)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn initialize_and_tools_list() {
        let (factory, _) = fake_factory(vec![]);
        let out = run(
            concat!(
                r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}"#,
                "\n",
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                "\n",
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                "\n"
            ),
            factory,
        )
        .await;
        assert_eq!(out.len(), 2, "notification must not produce a response");
        assert_eq!(out[0]["result"]["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(out[0]["result"]["serverInfo"]["name"], "devinorium-browser");
        let tools = out[1]["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 15);
        assert!(tools
            .iter()
            .all(|t| t["name"].as_str().unwrap().starts_with("browser_")));
    }

    #[tokio::test]
    async fn tools_call_runs_action_and_returns_text() {
        let (factory, launches) = fake_factory(vec![Ok(vec![ToolContent::Text("Page: t".into())])]);
        let out = run(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"https://a.b"}}}
"#,
            factory,
        )
        .await;
        assert_eq!(launches.lock().unwrap().len(), 1, "engine launched once");
        let content = &out[0]["result"]["content"];
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[0]["text"], "Page: t");
        assert!(out[0]["result"].get("isError").is_none());
    }

    #[tokio::test]
    async fn image_content_serializes_as_base64() {
        let (factory, _) = fake_factory(vec![Ok(vec![ToolContent::ImagePng(vec![1, 2, 3])])]);
        let out = run(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_screenshot","arguments":{}}}
"#,
            factory,
        )
        .await;
        let c = &out[0]["result"]["content"][0];
        assert_eq!(c["type"], "image");
        assert_eq!(c["mimeType"], "image/png");
        assert_eq!(c["data"], "AQID");
    }

    #[tokio::test]
    async fn launch_failure_surfaces_as_tool_error_not_protocol_error() {
        let factory: EngineFactory =
            Arc::new(|| Box::pin(async { Err("no Chromium/Chrome binary found".to_string()) }));
        let out = run(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}
"#,
            factory,
        )
        .await;
        assert!(out[0]["error"].is_null() || out[0].get("error").is_none());
        assert_eq!(out[0]["result"]["isError"], true);
        assert!(out[0]["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("no Chromium"));
    }

    #[tokio::test]
    async fn launch_failure_does_not_stick() {
        // First call fails, second succeeds: a missing binary or transient
        // spawn error must not brick the server for its lifetime.
        let attempts = Arc::new(Mutex::new(0));
        let factory: EngineFactory = {
            let attempts = attempts.clone();
            Arc::new(move || {
                let attempts = attempts.clone();
                Box::pin(async move {
                    let n = {
                        let mut g = attempts.lock().unwrap();
                        *g += 1;
                        *g
                    };
                    if n == 1 {
                        Err("spawn failed".to_string())
                    } else {
                        Ok(Box::new(FakeEngine::new(vec![])) as Box<dyn Engine>)
                    }
                })
            })
        };
        let mut slot = EngineSlot { engine: None };
        assert!(slot.get(&factory).await.is_err());
        assert!(slot.get(&factory).await.is_ok());
        assert_eq!(*attempts.lock().unwrap(), 2);
    }

    #[tokio::test]
    async fn engine_relaunch_after_dead() {
        // First factory result reports dead; the slot must drop it and
        // launch a fresh engine instead of reusing the corpse.
        let calls = Arc::new(Mutex::new(0));
        let factory: EngineFactory = {
            let calls = calls.clone();
            Arc::new(move || {
                let calls = calls.clone();
                Box::pin(async move {
                    let n = {
                        let mut g = calls.lock().unwrap();
                        *g += 1;
                        *g
                    };
                    let mut engine = FakeEngine::new(vec![]);
                    engine.alive = n > 1;
                    Ok(Box::new(engine) as Box<dyn Engine>)
                })
            })
        };
        let mut slot = EngineSlot { engine: None };
        slot.get(&factory).await.unwrap();
        assert_eq!(*calls.lock().unwrap(), 1);
        // The stored engine reports dead: the next get must relaunch.
        slot.get(&factory).await.unwrap();
        assert_eq!(*calls.lock().unwrap(), 2);
        // Alive engine is reused, not relaunched.
        slot.get(&factory).await.unwrap();
        assert_eq!(*calls.lock().unwrap(), 2);
    }

    #[tokio::test]
    async fn protocol_errors() {
        let (factory, _) = fake_factory(vec![]);
        let out = run(
            concat!(
                "{not json}\n",
                r#"{"jsonrpc":"2.0","id":1,"method":"bogus/method"}"#, "\n",
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope"}}"#, "\n",
                r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_click","arguments":{}}}"#, "\n",
                r#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#, "\n",
                r#"{"jsonrpc":"2.0","id":5,"method":"prompts/list"}"#, "\n",
                r#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#, "\n"
            ),
            factory,
        )
        .await;
        assert_eq!(out[0]["error"]["code"], -32700);
        assert_eq!(out[1]["error"]["code"], -32601);
        assert_eq!(out[2]["error"]["code"], -32602, "unknown tool");
        assert_eq!(out[3]["error"]["code"], -32602, "missing ref/selector");
        assert_eq!(out[4]["result"]["resources"], json!([]));
        assert_eq!(out[5]["result"]["prompts"], json!([]));
        assert_eq!(out[6]["result"], json!({}));
    }
}
