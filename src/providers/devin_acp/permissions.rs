use agent_client_protocol::schema::v1::{
    PermissionOption as AcpPermissionOption, PermissionOptionKind as AcpPermissionOptionKind,
    RequestPermissionOutcome, RequestPermissionRequest, SelectedPermissionOutcome,
};

use crate::providers::{PermissionCallback, PermissionOutcome, PermissionRequest, PermissionOption};

pub(crate) async fn handle_permission_request(
    request: RequestPermissionRequest,
    permission_mode: &str,
    permission_callback: Option<&PermissionCallback>,
) -> RequestPermissionOutcome {
    if is_bypass_mode(permission_mode) {
        if let Some(option) = select_allow_option(&request.options) {
            tracing::info!(
                scope = %request.tool_call.tool_call_id,
                option_id = %option.option_id,
                "auto-allowing permission request in bypass mode"
            );
            return RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                option.option_id.clone(),
            ));
        }
        tracing::warn!(
            scope = %request.tool_call.tool_call_id,
            "bypass mode but no allow option found; forwarding to permission callback"
        );
    }

    if let Some(callback) = permission_callback {
        let permission_request = map_permission_request(&request);
        tracing::info!(scope = %permission_request.scope, "forwarding acp permission request");
        match callback(permission_request).await {
            PermissionOutcome::Allow { option_id } => {
                tracing::info!(option_id = %option_id, "permission request allowed");
                RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(option_id))
            }
            PermissionOutcome::Cancel => RequestPermissionOutcome::Cancelled,
        }
    } else {
        tracing::warn!("no permission callback configured; rejecting ACP permission request");
        RequestPermissionOutcome::Cancelled
    }
}

pub(crate) fn is_bypass_mode(mode: &str) -> bool {
    matches!(mode.trim().to_lowercase().as_str(), "bypass" | "yolo")
}

pub(crate) fn select_allow_option(options: &[AcpPermissionOption]) -> Option<&AcpPermissionOption> {
    options
        .iter()
        .find(|o| matches!(o.kind, AcpPermissionOptionKind::AllowOnce))
        .or_else(|| options.iter().find(|o| matches!(o.kind, AcpPermissionOptionKind::AllowAlways)))
}

pub(crate) fn map_permission_request(request: &RequestPermissionRequest) -> PermissionRequest {
    let request_id = uuid::Uuid::new_v4().to_string();
    let scope = format!("{}", request.tool_call.tool_call_id);
    let title = request
        .tool_call
        .fields
        .title
        .clone()
        .or_else(|| {
            request
                .tool_call
                .fields
                .kind
                .as_ref()
                .map(|k| format!("{k:?}"))
        })
        .unwrap_or_else(|| "Run command".to_string());
    let input = request
        .tool_call
        .fields
        .raw_input
        .as_ref()
        .map(|v| serde_json::to_string_pretty(v).unwrap_or_else(|_| v.to_string()));
    let options = request.options.iter().map(map_permission_option).collect();
    PermissionRequest {
        request_id,
        scope,
        title,
        input,
        options,
    }
}

pub(crate) fn map_permission_option(option: &AcpPermissionOption) -> PermissionOption {
    PermissionOption {
        id: option.option_id.to_string(),
        kind: format!("{:?}", option.kind),
        label: Some(option.name.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    use agent_client_protocol::schema::v1::{
        PermissionOption as AcpPermissionOption, PermissionOptionKind as AcpPermissionOptionKind,
        RequestPermissionRequest, SessionId, ToolCallUpdateFields,
    };

    fn make_permission_request(options: Vec<AcpPermissionOption>) -> RequestPermissionRequest {
        RequestPermissionRequest::new(
            SessionId::new("sid"),
            agent_client_protocol::schema::v1::ToolCallUpdate::new(
                "tc-1",
                ToolCallUpdateFields::new(),
            ),
            options,
        )
    }

    fn recording_callback(allowed_id: &'static str, called: Arc<AtomicBool>) -> PermissionCallback {
        Arc::new(move |_req| {
            called.store(true, Ordering::SeqCst);
            Box::pin(async move { PermissionOutcome::Allow { option_id: allowed_id.into() } })
        })
    }

    #[tokio::test]
    async fn bypass_auto_selects_allow_once() {
        let options = vec![
            AcpPermissionOption::new("allow-once", "Allow", AcpPermissionOptionKind::AllowOnce),
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("allow-once", called.clone()));

        let outcome = handle_permission_request(request, "bypass", callback.as_ref()).await;

        assert!(!called.load(Ordering::SeqCst), "callback should not be invoked in bypass mode");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-once");
    }

    #[tokio::test]
    async fn bypass_falls_back_to_allow_always() {
        let options = vec![
            AcpPermissionOption::new("allow-always", "Always", AcpPermissionOptionKind::AllowAlways),
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);

        let outcome = handle_permission_request(request, "bypass", None).await;

        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-always");
    }

    #[tokio::test]
    async fn bypass_falls_back_to_callback_when_no_allow_option() {
        let options = vec![
            AcpPermissionOption::new("reject", "Cancel", AcpPermissionOptionKind::RejectOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("reject", called.clone()));

        let outcome = handle_permission_request(request, "bypass", callback.as_ref()).await;

        assert!(called.load(Ordering::SeqCst), "callback should be invoked when no allow option");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "reject");
    }

    #[tokio::test]
    async fn normal_mode_forwards_to_callback() {
        let options = vec![
            AcpPermissionOption::new("allow-once", "Allow", AcpPermissionOptionKind::AllowOnce),
        ];
        let request = make_permission_request(options);
        let called = Arc::new(AtomicBool::new(false));
        let callback = Some(recording_callback("allow-once", called.clone()));

        let outcome = handle_permission_request(request, "normal", callback.as_ref()).await;

        assert!(called.load(Ordering::SeqCst), "callback should be invoked in normal mode");
        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-once");
    }

    #[tokio::test]
    async fn yolo_is_treated_as_bypass() {
        let options = vec![
            AcpPermissionOption::new("allow-always", "Always", AcpPermissionOptionKind::AllowAlways),
        ];
        let request = make_permission_request(options);

        let outcome = handle_permission_request(request, " yolo ", None).await;

        let RequestPermissionOutcome::Selected(selected) = outcome else {
            panic!("expected Selected outcome, got {:?}", outcome);
        };
        assert_eq!(selected.option_id.0.as_ref(), "allow-always");
    }

    #[test]
    fn map_permission_request_uses_tool_call_id_as_scope() {
        let options = vec![AcpPermissionOption::new(
            "allow-once",
            "Allow",
            AcpPermissionOptionKind::AllowOnce,
        )];
        let request = make_permission_request(options);
        let mapped = map_permission_request(&request);
        assert_eq!(mapped.scope, "tc-1");
        assert_eq!(mapped.options.len(), 1);
        assert_eq!(mapped.options[0].id, "allow-once");
    }
}
