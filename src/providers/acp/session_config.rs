use agent_client_protocol::schema::v1::{
    SessionConfigId, SessionConfigKind, SessionConfigOption, SessionConfigOptionValue,
    SessionConfigSelectOptions, SessionId, SetSessionConfigOptionRequest,
};

use agent_client_protocol::{Agent, ConnectionTo};

use super::{AcpProvider, AgentKind};
use crate::providers::SendOptions;

impl AcpProvider {
    /// Prepend a mode instruction to the prompt so the agent behaves
    /// according to the selected composer mode (plan/ask/code).
    /// This is the fallback for ACP agents that do not expose a native
    /// `interaction_mode` session config option, and a supplement for those
    /// that do: the markup conventions are devinorium's own.
    pub fn apply_interaction_mode_prefix(prompt: String, mode: &str) -> String {
        // A leading / is a native slash command (a skill, /compact, ...) —
        // prepending a mode preamble would stop the agent from resolving it.
        if prompt.starts_with('/') {
            return prompt;
        }
        crate::providers::apply_interaction_mode_prefix(prompt, mode)
    }
}

pub(crate) async fn apply_session_config(
    connection: &ConnectionTo<Agent>,
    session_id: &str,
    kind: AgentKind,
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

        tracing::info!(session_id = %session_id, model = %model, "setting acp model");
        if let Err(e) = connection
            .send_request(SetSessionConfigOptionRequest::new(
                session_id.clone(),
                SessionConfigId::new("model"),
                SessionConfigOptionValue::value_id(model),
            ))
            .block_task()
            .await
        {
            tracing::warn!(session_id = %session_id, error = %e, "failed to set acp model");
        }
    }

    // Agents that expose a `reasoning_effort` select option (Grok) get the
    // composer's effort choice applied here. An effort the agent does not
    // advertise is dropped rather than silently remapped, so the session
    // keeps the agent's own default.
    if let Some(requested) = options.reasoning_effort.as_deref() {
        let requested = requested.trim();
        if let Some(effort_opt) = config_options
            .iter()
            .find(|o| o.id.0.as_ref() == "reasoning_effort")
        {
            let choices = select_values(effort_opt);
            if !requested.is_empty() && choices.iter().any(|v| v == requested) {
                tracing::info!(session_id = %session_id, effort = %requested, "setting acp reasoning effort");
                if let Err(e) = connection
                    .send_request(SetSessionConfigOptionRequest::new(
                        session_id.clone(),
                        SessionConfigId::new("reasoning_effort"),
                        SessionConfigOptionValue::value_id(requested.to_string()),
                    ))
                    .block_task()
                    .await
                {
                    tracing::warn!(session_id = %session_id, error = %e, "failed to set acp reasoning effort");
                }
            } else if !requested.is_empty() {
                tracing::warn!(
                    session_id = %session_id,
                    requested = %requested,
                    "reasoning effort not in ACP choices, keeping agent default"
                );
            }
        }
    }

    // An agent that advertises a select option for the output cap gets the
    // thread's override applied verbatim. ACP has no free-form number input,
    // so the cap is only sent when the requested value is one of the
    // agent's own choices; otherwise it stays display-only.
    if let Some(cap) = options.max_output_tokens {
        match output_token_option(config_options, cap) {
            Some(opt) => {
                let opt_id = opt.id.clone();
                tracing::info!(session_id = %session_id, value = %cap, "setting acp output token cap");
                if let Err(e) = connection
                    .send_request(SetSessionConfigOptionRequest::new(
                        session_id.clone(),
                        opt_id,
                        SessionConfigOptionValue::value_id(cap.to_string()),
                    ))
                    .block_task()
                    .await
                {
                    tracing::warn!(session_id = %session_id, error = %e, "failed to set acp output token cap");
                }
            }
            None => {
                tracing::debug!(
                    session_id = %session_id,
                    value = %cap,
                    "agent exposes no output-token option; cap is advisory only"
                );
            }
        }
    }

    if let Some(option_id) = kind.interaction_mode_option() {
        if let Some(interaction_opt) = config_options.iter().find(|o| o.id.0.as_ref() == option_id)
        {
            let choices = select_values(interaction_opt);
            let requested = options.interaction_mode.trim();
            let value = match kind.interaction_mode_value(requested, &choices) {
                Some(v) => v,
                None => {
                    if let Some(first) = choices.first() {
                        tracing::warn!(
                            session_id = %session_id,
                            requested = %requested,
                            value = %first,
                            "interaction mode not in ACP choices, using fallback"
                        );
                        first.clone()
                    } else {
                        tracing::warn!(
                            session_id = %session_id,
                            requested = %requested,
                            "ACP agent has no interaction mode choices, skipping"
                        );
                        return Ok(());
                    }
                }
            };

            if value != requested {
                tracing::info!(
                    session_id = %session_id,
                    requested = %requested,
                    value = %value,
                    "mapped interaction mode to provider value"
                );
            }

            tracing::info!(session_id = %session_id, value = %value, "setting acp interaction mode");
            if let Err(e) = connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session_id.clone(),
                    SessionConfigId::new(option_id),
                    SessionConfigOptionValue::value_id(value),
                ))
                .block_task()
                .await
            {
                tracing::warn!(session_id = %session_id, error = %e, "failed to set acp interaction mode");
            }
        }
    }

    if let Some(option_id) = kind.permission_mode_option() {
        if let Some(mode_opt) = config_options.iter().find(|o| o.id.0.as_ref() == option_id) {
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

            tracing::info!(session_id = %session_id, mode = %mode, "setting acp mode");
            if let Err(e) = connection
                .send_request(SetSessionConfigOptionRequest::new(
                    session_id.clone(),
                    SessionConfigId::new(option_id),
                    SessionConfigOptionValue::value_id(mode),
                ))
                .block_task()
                .await
            {
                tracing::warn!(session_id = %session_id, error = %e, "failed to set acp mode");
            }
        }
    }

    Ok(())
}

/// Session-config option ids an agent might use for an output token cap.
const OUTPUT_TOKEN_OPTION_IDS: &[&str] = &[
    "max_output_tokens",
    "max_output_token",
    "output_tokens",
    "max_tokens",
];

/// The config option to set for an output-cap request: a select whose
/// choices contain the value verbatim. `None` when the agent exposes no
/// matching option.
fn output_token_option(
    config_options: &[SessionConfigOption],
    value: u64,
) -> Option<&SessionConfigOption> {
    let want = value.to_string();
    config_options.iter().find(|o| {
        OUTPUT_TOKEN_OPTION_IDS.contains(&o.id.0.as_ref()) && select_values(o).contains(&want)
    })
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
    use agent_client_protocol::schema::v1::SessionConfigSelectOption;

    #[test]
    fn devin_session_mode_id_maps_interaction_modes() {
        assert_eq!(
            AgentKind::Devin.session_mode_id("plan").unwrap().0.as_ref(),
            "plan"
        );
        assert_eq!(
            AgentKind::Devin.session_mode_id("ask").unwrap().0.as_ref(),
            "ask"
        );
        assert_eq!(
            AgentKind::Devin.session_mode_id("code").unwrap().0.as_ref(),
            "default"
        );
        assert_eq!(
            AgentKind::Devin
                .session_mode_id("unknown")
                .unwrap()
                .0
                .as_ref(),
            "default"
        );
    }

    #[test]
    fn opencode_uses_config_option_not_session_mode() {
        assert!(AgentKind::Opencode.session_mode_id("plan").is_none());
        assert_eq!(AgentKind::Opencode.interaction_mode_option(), Some("mode"));
        assert!(AgentKind::Opencode.permission_mode_option().is_none());
    }

    #[test]
    fn grok_has_no_mode_options_and_stdio_args() {
        assert_eq!(AgentKind::Grok.id(), "grok");
        assert_eq!(AgentKind::Grok.name(), "Grok Code");
        assert_eq!(AgentKind::Grok.default_command(), "grok");
        assert_eq!(AgentKind::Grok.acp_args(), &["agent", "stdio"]);
        assert!(AgentKind::Grok.interaction_mode_option().is_none());
        assert!(AgentKind::Grok.permission_mode_option().is_none());
        assert!(AgentKind::Grok.session_mode_id("plan").is_none());
        assert!(AgentKind::Grok.version_manifest_url().is_none());
    }

    #[test]
    fn opencode_interaction_mode_maps_to_agent_choices() {
        let choices = vec!["build".to_string(), "plan".to_string()];
        assert_eq!(
            AgentKind::Opencode.interaction_mode_value("plan", &choices),
            Some("plan".to_string())
        );
        assert_eq!(
            AgentKind::Opencode.interaction_mode_value("code", &choices),
            Some("build".to_string())
        );
        assert_eq!(
            AgentKind::Opencode.interaction_mode_value("ask", &choices),
            Some("build".to_string())
        );
        assert_eq!(
            AgentKind::Opencode.interaction_mode_value("bogus", &choices),
            Some("build".to_string())
        );
    }

    #[test]
    fn devin_interaction_mode_prefers_requested_then_default() {
        let choices = vec!["default".to_string(), "plan".to_string(), "ask".to_string()];
        assert_eq!(
            AgentKind::Devin.interaction_mode_value("plan", &choices),
            Some("plan".to_string())
        );
        assert_eq!(
            AgentKind::Devin.interaction_mode_value("code", &choices),
            Some("default".to_string())
        );
        assert_eq!(
            AgentKind::Devin.interaction_mode_value("bogus", &choices),
            None
        );
    }

    #[test]
    fn output_token_option_matches_only_offered_values() {
        let opt = SessionConfigOption::select(
            "max_output_tokens",
            "Max output tokens",
            "4096",
            vec![
                SessionConfigSelectOption::new("2048", "2048"),
                SessionConfigSelectOption::new("4096", "4096"),
            ],
        );
        let other = SessionConfigOption::select(
            "model",
            "Model",
            "a",
            vec![SessionConfigSelectOption::new("4096", "a")],
        );
        let options = vec![other, opt];

        assert!(output_token_option(&options, 4096).is_some());
        // Not among the agent's choices: the cap is advisory, not sent.
        assert!(output_token_option(&options, 8192).is_none());
        // A select with a matching value but an unrelated id must not be hit.
        let model_only = vec![options[0].clone()];
        assert!(output_token_option(&model_only, 4096).is_none());
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_plan_instruction() {
        let out = AcpProvider::apply_interaction_mode_prefix("hello".into(), "plan");
        assert!(out.contains("Plan mode"));
        assert!(out.contains("hello"));
        assert!(out.contains("do not run tools"));
        assert!(out.contains("proposed_plan"));
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_ask_instruction() {
        let out = AcpProvider::apply_interaction_mode_prefix("hi".into(), "ask");
        assert!(out.contains("Ask mode"));
        assert!(out.contains("hi"));
        assert!(out.contains("do not use tools"));
    }

    #[test]
    fn apply_interaction_mode_prefix_adds_code_plan_hint() {
        let out = AcpProvider::apply_interaction_mode_prefix("go".into(), "code");
        assert!(out.starts_with("go\n\n"));
        assert!(out.contains("update_plan"));
    }

    #[test]
    fn apply_interaction_mode_prefix_leaves_slash_commands_alone() {
        // A leading / is a native ACP command — a mode preamble in front of
        // it would stop the agent from resolving the command name.
        let out = AcpProvider::apply_interaction_mode_prefix("/review src".into(), "plan");
        assert_eq!(out, "/review src");
    }
}
