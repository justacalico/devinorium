use agent_client_protocol::schema::v1::{
    SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionValue,
    SessionConfigSelectOptions, SessionId, SessionModeId, SetSessionConfigOptionRequest,
};

use agent_client_protocol::{Agent, ConnectionTo};

use super::DevinAcpProvider;
use crate::providers::SendOptions;

impl DevinAcpProvider {
    /// Prepend a mode instruction to the prompt so the Devin CLI
    /// behaves according to the selected composer mode (plan/ask/code).
    /// This is the fallback for ACP agents that do not expose a native
    /// `interaction_mode` session config option.
    pub fn apply_interaction_mode_prefix(prompt: String, mode: &str) -> String {
        match mode.trim().to_lowercase().as_str() {
            "plan" => format!(
                "You are in Plan mode. First produce a concise, decision-complete \
plan and do not run tools, edit files, or execute commands until the user \
confirms. Wrap the final plan in a `<proposed_plan>` block with \
`<step status=\"pending\">...</step>` children. At most one step may be \
`in_progress`.\n\n{prompt}"
            ),
            "ask" => format!(
                "You are in Ask mode. Answer the user's question directly and do \
not use tools, edit files, or execute commands.\n\n{prompt}"
            ),
            _ => format!(
                "{prompt}\n\nWhen working on a multi-step task, you may track \
progress by emitting `<update_plan explanation=\"...\"><step \
status=\"pending|in_progress|completed\">...</step></update_plan>` blocks. \
Only one step should be `in_progress` at a time."
            ),
        }
    }

    /// Map the composer interaction mode to a Devin ACP session mode id.
    /// `code` is sent as `default` to restore the normal builder mode.
    pub fn devin_mode_id(mode: &str) -> Option<SessionModeId> {
        let id = match mode.trim().to_lowercase().as_str() {
            "ask" => "ask",
            "plan" => "plan",
            "code" => "default",
            _ => "default",
        };
        if id.is_empty() {
            None
        } else {
            Some(SessionModeId::new(id))
        }
    }
}

pub(crate) async fn apply_session_config(
    connection: &ConnectionTo<Agent>,
    session_id: &str,
    default_model: &str,
    options: &SendOptions,
    config_options: Option<&[SessionConfigOption]>,
) -> anyhow::Result<()> {
    let config_options = match config_options {
        Some(c) => c,
        None => return Ok(()),
    };

    let session_id = SessionId::new(session_id.to_string());

    if let Some(model_opt) = config_options.iter().find(|o| o.id.0.as_ref() == "model") {
        let choices = select_values(model_opt);
        let requested = options.model.trim();
        let model = if !requested.is_empty() && choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if !default_model.is_empty() && choices.iter().any(|v| v == default_model) {
            default_model.to_string()
        } else if let Some(first) = choices.first() {
            first.clone()
        } else {
            return Ok(());
        };

        if !requested.is_empty() && requested != model {
            tracing::warn!(
                session_id = %session_id,
                requested = %requested,
                model = %model,
                "requested model not in ACP choices, using fallback"
            );
        }

        tracing::info!(session_id = %session_id, model = %model, "setting devin acp model");
        if let Err(e) = connection
            .send_request(SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new("model"),
                SessionConfigOptionValue::value_id(model),
            ))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp model");
        }
    }

    if let Some(interaction_opt) = config_options
        .iter()
        .find(|o| o.id.0.as_ref() == "interaction_mode")
    {
        let choices = select_values(interaction_opt);
        let requested = options.interaction_mode.trim();
        let mut value = if choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if requested == "code" {
            if let Some(v) = choices.iter().find(|v| *v == "default" || *v == "build") {
                tracing::info!(
                    session_id = %session_id,
                    requested = %requested,
                    value = %v,
                    "mapping code interaction mode to provider value"
                );
                v.clone()
            } else {
                requested.to_string()
            }
        } else {
            requested.to_string()
        };

        if !choices.iter().any(|v| v.as_str() == value) {
            if let Some(first) = choices.first() {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    value = %first,
                    "interaction mode not in ACP choices, using fallback"
                );
                value = first.clone();
            } else {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    "ACP agent has no interaction mode choices, skipping"
                );
            }
        }

        if choices.iter().any(|v| v.as_str() == value) {
            tracing::info!(session_id = %session_id, value = %value, "setting devin acp interaction mode");
            if let Err(e) = connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session_id.clone(),
                    SessionConfigId::new("interaction_mode"),
                    SessionConfigOptionValue::value_id(value),
                ))
                .block_task()
                .await
            {
                tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp interaction mode");
            }
        }
    }

    if let Some(mode_opt) = config_options.iter().find(|o| o.id.0.as_ref() == "mode") {
        let choices = select_values(mode_opt);
        let requested = options.permission_mode.trim();

        let mode = if choices.iter().any(|v| v == requested) {
            requested.to_string()
        } else if requested == "bypass" || requested == "yolo" {
            if let Some(v) = choices
                .iter()
                .find(|v| *v == "dangerous" || *v == "autonomous")
            {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    mode = %v,
                    "mapping permission mode alias to ACP mode"
                );
                v.clone()
            } else {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    "ACP agent has no auto-run mode, falling back"
                );
                if let Some(first) = choices.first() {
                    first.clone()
                } else {
                    return Ok(());
                }
            }
        } else if ["normal", "accept-edits", "smart", "ask", "plan"].contains(&requested) {
            if let Some(fallback) = choices
                .iter()
                .find(|v| *v == "normal")
                .or_else(|| choices.first())
            {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    fallback = %fallback,
                    "permission mode not in ACP choices, falling back"
                );
                fallback.clone()
            } else {
                return Ok(());
            }
        } else if let Some(first) = choices.first() {
            tracing::warn!(
                session_id = %session_id,
                requested = %requested,
                first = %first,
                "unknown permission mode, falling back to first available"
            );
            first.clone()
        } else {
            return Ok(());
        };

        tracing::info!(session_id = %session_id, mode = %mode, "setting devin acp mode");
        if let Err(e) = connection
            .send_request(SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new("mode"),
                SessionConfigOptionValue::value_id(mode),
            ))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, error = %e, "failed to set devin acp mode");
        }
    }

    Ok(())
}

pub(crate) fn select_values(opt: &SessionConfigOption) -> Vec<String> {
    match &opt.kind {
        SessionConfigKind::Select(select) => match &select.options {
            SessionConfigSelectOptions::Ungrouped(opts) => {
                opts.iter().map(|o| o.value.0.to_string()).collect()
            }
            SessionConfigSelectOptions::Grouped(groups) => groups
                .iter()
                .flat_map(|g| g.options.iter().map(|o| o.value.0.to_string()))
                .collect(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn devin_mode_id_maps_interaction_modes() {
        assert_eq!(
            DevinAcpProvider::devin_mode_id("plan").unwrap().0.as_ref(),
            "plan"
        );
        assert_eq!(
            DevinAcpProvider::devin_mode_id("ask").unwrap().0.as_ref(),
            "ask"
        );
        assert_eq!(
            DevinAcpProvider::devin_mode_id("code").unwrap().0.as_ref(),
            "default"
        );
        assert_eq!(
            DevinAcpProvider::devin_mode_id("unknown")
                .unwrap()
                .0
                .as_ref(),
            "default"
        );
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_plan_instruction() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("hello".into(), "plan");
        assert!(out.contains("Plan mode"));
        assert!(out.contains("hello"));
        assert!(out.contains("do not run tools"));
        assert!(out.contains("proposed_plan"));
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_ask_instruction() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("hi".into(), "ask");
        assert!(out.contains("Ask mode"));
        assert!(out.contains("hi"));
        assert!(out.contains("do not use tools"));
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_code_plan_hint() {
        let out = DevinAcpProvider::apply_interaction_mode_prefix("go".into(), "code");
        assert!(out.starts_with("go\n\n"));
        assert!(out.contains("update_plan"));
    }
}
