//! Wire types for the Codex app-server JSON-RPC protocol.
//!
//! `codex app-server --stdio` speaks newline-delimited JSON-RPC: client
//! requests are `{id, method, params}`, responses are `{id, result}` or
//! `{id, error}`, server notifications are `{method, params}`, and server
//! requests are `{id, method, params}` that we must answer. Only the slice of
//! the protocol Devinorium uses is typed here; everything else rides through
//! as raw `serde_json::Value`.

use serde::Deserialize;
use serde_json::Value;

/// One decoded message read from the server's stdout.
#[derive(Debug)]
pub enum Incoming {
    /// Response to one of our requests.
    Response {
        id: Value,
        result: Result<Value, String>,
    },
    /// A server-initiated request we must respond to (approvals, user input).
    Request {
        id: Value,
        method: String,
        params: Value,
    },
    /// A server notification (no response expected).
    Notification { method: String, params: Value },
}

/// Classify one line of server output. Returns `None` for blank or
/// unparseable lines.
pub fn parse_message(line: &str) -> Option<Incoming> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let msg: Value = serde_json::from_str(line).ok()?;
    let obj = msg.as_object()?;

    if let Some(method) = obj.get("method").and_then(Value::as_str) {
        let params = obj.get("params").cloned().unwrap_or(Value::Null);
        if let Some(id) = obj.get("id") {
            return Some(Incoming::Request {
                id: id.clone(),
                method: method.to_string(),
                params,
            });
        }
        return Some(Incoming::Notification {
            method: method.to_string(),
            params,
        });
    }

    if let Some(id) = obj.get("id") {
        if let Some(result) = obj.get("result") {
            return Some(Incoming::Response {
                id: id.clone(),
                result: Ok(result.clone()),
            });
        }
        if let Some(error) = obj.get("error") {
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| error.to_string());
            return Some(Incoming::Response {
                id: id.clone(),
                result: Err(message),
            });
        }
    }

    None
}

/// `thread/start` and `thread/resume` response: we only need the thread id.
#[derive(Debug, Deserialize)]
pub struct ThreadResponse {
    pub thread: Thread,
}

#[derive(Debug, Deserialize)]
pub struct Thread {
    pub id: String,
}

/// `turn/start` response and the `turn` embedded in `turn/completed`.
#[derive(Debug, Deserialize)]
pub struct TurnResponse {
    pub turn: Turn,
}

#[derive(Debug, Deserialize)]
pub struct Turn {
    pub id: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub error: Option<TurnError>,
}

#[derive(Debug, Deserialize)]
pub struct TurnError {
    #[serde(default)]
    pub message: String,
}

/// A thread item from `item/started` / `item/completed`. Fields beyond `id`
/// and `type` stay generic — `events.rs` reads what it needs per kind.
#[derive(Debug, Deserialize)]
pub struct Item {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(flatten)]
    pub fields: serde_json::Map<String, Value>,
}

/// `thread/tokenUsage/updated` payload.
#[derive(Debug, Deserialize)]
pub struct TokenUsage {
    pub total: TokenBreakdown,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TokenBreakdown {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_output_tokens: u64,
    pub cached_input_tokens: u64,
    pub cache_write_input_tokens: u64,
    pub total_tokens: u64,
}

/// `model/list` response.
#[derive(Debug, Deserialize)]
pub struct ModelListResponse {
    #[serde(default)]
    pub data: Vec<CodexModel>,
}

/// One entry in `supportedReasoningEfforts`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReasoningEffortOption {
    pub reasoning_effort: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexModel {
    pub id: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub default_reasoning_effort: Option<String>,
    #[serde(default)]
    pub supported_reasoning_efforts: Vec<ReasoningEffortOption>,
}

/// `item/tool/requestUserInput` question.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInputQuestion {
    pub id: String,
    #[serde(default)]
    pub header: String,
    pub question: String,
    #[serde(default)]
    pub options: Option<Vec<UserInputOption>>,
    #[serde(default)]
    pub is_other: bool,
}

#[derive(Debug, Deserialize)]
pub struct UserInputOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_response_result() {
        let msg = parse_message(r#"{"id":1,"result":{"turn":{"id":"t1"}}}"#).unwrap();
        match msg {
            Incoming::Response { id, result } => {
                assert_eq!(id, json!(1));
                assert_eq!(result.unwrap()["turn"]["id"], "t1");
            }
            _ => panic!("expected response"),
        }
    }

    #[test]
    fn parses_response_error() {
        let msg = parse_message(r#"{"id":"a","error":{"code":-1,"message":"boom"}}"#).unwrap();
        match msg {
            Incoming::Response { id, result } => {
                assert_eq!(id, json!("a"));
                assert_eq!(result.unwrap_err(), "boom");
            }
            _ => panic!("expected response"),
        }
    }

    #[test]
    fn parses_notification_and_request() {
        let note =
            parse_message(r#"{"method":"turn/completed","params":{"threadId":"t"}}"#).unwrap();
        assert!(
            matches!(note, Incoming::Notification { method, .. } if method == "turn/completed")
        );

        let req = parse_message(
            r#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"command":"ls"}}"#,
        )
        .unwrap();
        match req {
            Incoming::Request { id, method, params } => {
                assert_eq!(id, json!(7));
                assert_eq!(method, "item/commandExecution/requestApproval");
                assert_eq!(params["command"], "ls");
            }
            _ => panic!("expected request"),
        }
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_message("").is_none());
        assert!(parse_message("not json").is_none());
        assert!(parse_message(r#"{"foo":1}"#).is_none());
        assert!(parse_message("[1,2]").is_none());
    }

    #[test]
    fn item_keeps_extra_fields() {
        let item: Item = serde_json::from_value(json!({
            "id": "i1",
            "type": "commandExecution",
            "command": "ls -la",
            "status": "completed",
            "exitCode": 0
        }))
        .unwrap();
        assert_eq!(item.kind, "commandExecution");
        assert_eq!(item.fields["command"], "ls -la");
        assert_eq!(item.fields["exitCode"], 0);
    }

    #[test]
    fn token_usage_reads_totals() {
        let usage: TokenUsage = serde_json::from_value(json!({
            "total": {
                "inputTokens": 10,
                "outputTokens": 5,
                "reasoningOutputTokens": 2,
                "cachedInputTokens": 3,
                "cacheWriteInputTokens": 1,
                "totalTokens": 15
            }
        }))
        .unwrap();
        assert_eq!(usage.total.total_tokens, 15);
        assert_eq!(usage.total.reasoning_output_tokens, 2);
    }
}
