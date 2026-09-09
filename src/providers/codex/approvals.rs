//! Server-initiated requests: approval prompts, tool user-input forms, and
//! MCP elicitations, plus the permission-mode → sandbox/policy mapping Codex
//! expects on `thread/start` and `turn/start`.

use serde_json::{json, Value};

use crate::providers::{
    AskCallback, AskOption, AskOutcome, AskQuestion, AskRequest, PermissionCallback,
    PermissionOption, PermissionOutcome, PermissionRequest,
};

use super::wire::UserInputQuestion;

/// The approval/sandbox triple codex wants on `thread/start` and `turn/start`
/// for one Devinorium permission mode.
pub struct ThreadConfig {
    pub approval_policy: &'static str,
    pub sandbox: &'static str,
    /// Who reviews approval requests. `auto_review` routes them through a
    /// codex subagent, which costs extra tokens — only "smart" opts in.
    pub approvals_reviewer: &'static str,
    pub sandbox_policy: Value,
}

/// Map a Devinorium permission mode ("normal", "accept-edits", "smart",
/// "bypass") onto codex's `approvalPolicy` + `sandbox` pair.
pub fn thread_config(permission_mode: &str) -> ThreadConfig {
    match permission_mode.trim().to_lowercase().as_str() {
        "bypass" | "yolo" => ThreadConfig {
            approval_policy: "never",
            sandbox: "danger-full-access",
            approvals_reviewer: "user",
            sandbox_policy: json!({ "type": "dangerFullAccess" }),
        },
        "smart" => ThreadConfig {
            approval_policy: "on-request",
            sandbox: "workspace-write",
            approvals_reviewer: "auto_review",
            sandbox_policy: workspace_write_policy(),
        },
        _ => ThreadConfig {
            approval_policy: "on-request",
            sandbox: "workspace-write",
            approvals_reviewer: "user",
            sandbox_policy: workspace_write_policy(),
        },
    }
}

fn workspace_write_policy() -> Value {
    json!({ "type": "workspaceWrite" })
}

/// How to answer a server request: either a JSON-RPC result payload or an
/// error the caller should send back.
pub enum ServerRequestResponse {
    Result(Value),
    MethodNotFound,
}

/// Handle one server→client request. Approval requests are forwarded to the
/// permission callback; `item/tool/requestUserInput` goes to the ask
/// callback; MCP elicitations are declined (form mapping is not supported);
/// anything else gets `MethodNotFound`.
pub async fn handle_server_request(
    method: &str,
    params: &Value,
    permission_callback: Option<&PermissionCallback>,
    ask_callback: Option<&AskCallback>,
) -> ServerRequestResponse {
    match method {
        "item/commandExecution/requestApproval" | "execCommandApproval" => {
            let title = params
                .get("reason")
                .and_then(Value::as_str)
                .or_else(|| params.get("command").and_then(Value::as_str))
                .unwrap_or("Run command")
                .to_string();
            approval_response(
                PermissionRequest {
                    request_id: request_id(params),
                    scope: "exec".into(),
                    title,
                    input: params
                        .get("command")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    options: decision_options(),
                },
                permission_callback,
                |outcome| match outcome {
                    Some(decision) => json!({ "decision": decision }),
                    None => json!({ "decision": "decline" }),
                },
            )
            .await
        }
        "item/fileChange/requestApproval" | "applyPatchApproval" => {
            let title = params
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("Apply file changes")
                .to_string();
            approval_response(
                PermissionRequest {
                    request_id: request_id(params),
                    scope: "edit".into(),
                    title,
                    input: None,
                    options: decision_options(),
                },
                permission_callback,
                |outcome| match outcome {
                    Some(decision) => json!({ "decision": decision }),
                    None => json!({ "decision": "decline" }),
                },
            )
            .await
        }
        "item/permissions/requestApproval" => {
            let title = params
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("Additional permissions")
                .to_string();
            approval_response(
                PermissionRequest {
                    request_id: request_id(params),
                    scope: "permissions".into(),
                    title,
                    input: params.get("permissions").map(|p| p.to_string()),
                    options: decision_options(),
                },
                permission_callback,
                |outcome| match outcome.as_deref() {
                    Some("accept") | Some("acceptForSession") => {
                        json!({ "permissions": params.get("permissions").cloned().unwrap_or(json!({})) })
                    }
                    _ => json!({ "permissions": {} }),
                },
            )
            .await
        }
        "item/tool/requestUserInput" => user_input_response(params, ask_callback).await,
        "mcpServer/elicitation/request" => ServerRequestResponse::Result(
            json!({ "action": "decline", "content": null, "_meta": null }),
        ),
        _ => ServerRequestResponse::MethodNotFound,
    }
}

/// Run a permission request through the callback and convert the outcome
/// into the method's response payload via `build`.
async fn approval_response(
    request: PermissionRequest,
    callback: Option<&PermissionCallback>,
    build: impl FnOnce(Option<String>) -> Value,
) -> ServerRequestResponse {
    let Some(callback) = callback else {
        tracing::warn!(scope = %request.scope, "no permission callback; declining codex request");
        return ServerRequestResponse::Result(build(None));
    };
    let outcome = callback(request).await;
    let decision = match outcome {
        PermissionOutcome::Allow { option_id } => Some(option_id),
        PermissionOutcome::Cancel => Some("cancel".into()),
    };
    ServerRequestResponse::Result(build(decision))
}

fn request_id(params: &Value) -> String {
    params
        .get("approvalId")
        .and_then(Value::as_str)
        .or_else(|| params.get("itemId").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string()
}

/// Accept / accept-for-session / decline / cancel, labelled the way the
/// frontend renders permission option kinds.
fn decision_options() -> Vec<PermissionOption> {
    vec![
        PermissionOption {
            id: "accept".into(),
            kind: "AllowOnce".into(),
            label: Some("Approve".into()),
        },
        PermissionOption {
            id: "acceptForSession".into(),
            kind: "AllowAlways".into(),
            label: Some("Approve for session".into()),
        },
        PermissionOption {
            id: "decline".into(),
            kind: "RejectOnce".into(),
            label: Some("Deny".into()),
        },
        PermissionOption {
            id: "cancel".into(),
            kind: "RejectAlways".into(),
            label: Some("Cancel".into()),
        },
    ]
}

/// `item/tool/requestUserInput` is codex's form prompt: map its questions
/// onto the ask callback and translate the answers back.
async fn user_input_response(
    params: &Value,
    ask_callback: Option<&AskCallback>,
) -> ServerRequestResponse {
    let questions: Vec<UserInputQuestion> = params
        .get("questions")
        .and_then(|q| serde_json::from_value(q.clone()).ok())
        .unwrap_or_default();

    let Some(callback) = ask_callback else {
        return ServerRequestResponse::Result(json!({ "answers": {} }));
    };
    if questions.is_empty() {
        return ServerRequestResponse::Result(json!({ "answers": {} }));
    }

    let ask = AskRequest {
        request_id: request_id(params),
        message: "Codex is asking for input".into(),
        questions: questions
            .iter()
            .map(|q| AskQuestion {
                id: q.id.clone(),
                prompt: q.question.clone(),
                description: (!q.header.is_empty()).then(|| q.header.clone()),
                field_type: if q.options.is_some() {
                    "single_select"
                } else {
                    "text"
                }
                .to_string(),
                options: q
                    .options
                    .as_deref()
                    .unwrap_or_default()
                    .iter()
                    .map(|o| AskOption {
                        value: o.label.clone(),
                        label: if o.description.is_empty() {
                            o.label.clone()
                        } else {
                            format!("{} — {}", o.label, o.description)
                        },
                    })
                    .collect(),
                required: !q.is_other,
            })
            .collect(),
    };

    let answers = match callback(ask).await {
        AskOutcome::Answers(map) => map,
        AskOutcome::Cancel => Default::default(),
    };

    let mut out = serde_json::Map::new();
    for q in &questions {
        let value = answers.get(&q.id).map(|v| match v {
            Value::Array(items) => items
                .iter()
                .map(|i| {
                    i.as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| i.to_string())
                })
                .collect(),
            Value::String(s) => vec![s.clone()],
            other => vec![other.to_string()],
        });
        if let Some(list) = value {
            out.insert(q.id.clone(), json!({ "answers": list }));
        }
    }
    ServerRequestResponse::Result(json!({ "answers": out }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::Arc;

    fn allow_callback() -> PermissionCallback {
        Arc::new(|_req| {
            Box::pin(async move {
                PermissionOutcome::Allow {
                    option_id: "accept".into(),
                }
            }) as Pin<Box<dyn Future<Output = PermissionOutcome> + Send>>
        })
    }

    #[test]
    fn thread_config_maps_modes() {
        let c = thread_config("bypass");
        assert_eq!(c.approval_policy, "never");
        assert_eq!(c.sandbox, "danger-full-access");
        let c = thread_config("normal");
        assert_eq!(c.approval_policy, "on-request");
        assert_eq!(c.sandbox, "workspace-write");
        assert_eq!(c.approvals_reviewer, "user");
        let c = thread_config("smart");
        assert_eq!(c.approvals_reviewer, "auto_review");
    }

    #[tokio::test]
    async fn command_approval_accepts_via_callback() {
        let params = json!({"itemId":"i1","command":"rm -rf /tmp/x","reason":"cleanup"});
        let resp = handle_server_request(
            "item/commandExecution/requestApproval",
            &params,
            Some(&allow_callback()),
            None,
        )
        .await;
        let ServerRequestResponse::Result(v) = resp else {
            panic!("expected result")
        };
        assert_eq!(v["decision"], "accept");
    }

    #[tokio::test]
    async fn command_approval_declines_without_callback() {
        let params = json!({"itemId":"i1","command":"ls"});
        let resp =
            handle_server_request("item/commandExecution/requestApproval", &params, None, None)
                .await;
        let ServerRequestResponse::Result(v) = resp else {
            panic!("expected result")
        };
        assert_eq!(v["decision"], "decline");
    }

    #[tokio::test]
    async fn file_change_cancel_maps_to_cancel() {
        let cb: PermissionCallback = Arc::new(|_| {
            Box::pin(async move { PermissionOutcome::Cancel })
                as Pin<Box<dyn Future<Output = PermissionOutcome> + Send>>
        });
        let resp = handle_server_request(
            "item/fileChange/requestApproval",
            &json!({"itemId":"i2","reason":"edit"}),
            Some(&cb),
            None,
        )
        .await;
        let ServerRequestResponse::Result(v) = resp else {
            panic!("expected result")
        };
        assert_eq!(v["decision"], "cancel");
    }

    #[tokio::test]
    async fn permissions_request_returns_requested_on_accept() {
        let params = json!({"itemId":"i3","permissions":{"network":{"enabled":true}}});
        let resp = handle_server_request(
            "item/permissions/requestApproval",
            &params,
            Some(&allow_callback()),
            None,
        )
        .await;
        let ServerRequestResponse::Result(v) = resp else {
            panic!("expected result")
        };
        assert_eq!(v["permissions"]["network"]["enabled"], true);
    }

    #[tokio::test]
    async fn user_input_maps_ask_answers() {
        let cb: AskCallback = Arc::new(|req| {
            assert_eq!(req.questions.len(), 1);
            assert_eq!(req.questions[0].field_type, "single_select");
            let mut m = HashMap::new();
            m.insert("q1".to_string(), json!("yes"));
            Box::pin(async move { AskOutcome::Answers(m) })
                as Pin<Box<dyn Future<Output = AskOutcome> + Send>>
        });
        let params = json!({
            "itemId":"i4","isBlocking":true,
            "questions":[{"id":"q1","header":"Pick","question":"Continue?","options":[{"label":"yes","description":""}]}]
        });
        let resp =
            handle_server_request("item/tool/requestUserInput", &params, None, Some(&cb)).await;
        let ServerRequestResponse::Result(v) = resp else {
            panic!("expected result")
        };
        assert_eq!(v["answers"]["q1"]["answers"][0], "yes");
    }

    #[tokio::test]
    async fn unknown_method_is_not_found() {
        let resp =
            handle_server_request("account/chatgptAuthTokens/refresh", &json!({}), None, None)
                .await;
        assert!(matches!(resp, ServerRequestResponse::MethodNotFound));
    }
}
