//! Context usage: token estimates for the composer plus the pre-send
//! context-limit check.
//!
//! The provider session holds the real context; the stored messages are an
//! approximation of it (tool calls and system prompts never reach the
//! database). The estimate only has to be close enough to warn early and to
//! stop sends that would obviously overflow the window. Providers that
//! report no context limit (Codex returns 0, offline fallbacks too) skip
//! enforcement entirely — there is nothing meaningful to compare against.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use once_cell::sync::Lazy;
use serde::Serialize;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::{ThreadRow, UserRow};
use crate::providers::{apply_interaction_mode_prefix, tokens, ModelInfo};
use crate::AppState;

use super::context_refs::prompt_with_refs;
use super::machine_refs::prompt_with_machine_refs;
use super::send::SendInput;
use super::thread_refs::prompt_with_thread_refs;

/// Reserve for the model's reply when the thread has no explicit cap and
/// the model does not advertise one either.
const DEFAULT_OUTPUT_HEADROOM: u64 = 8_192;

/// How long a provider's model catalog may be reused. `list_models` can
/// spawn the provider binary, so it must not run per keystroke or per send.
const MODEL_CACHE_TTL: Duration = Duration::from_secs(300);

/// What `GET /api/threads/:id/context` reports.
#[derive(Debug, Clone, Serialize)]
pub struct ContextUsageOut {
    /// Estimated tokens the provider session would see right now.
    pub used_tokens: u64,
    /// The model's advertised context window; 0 when unknown.
    pub context_limit: u64,
    /// The model's advertised output cap; 0 when unknown.
    pub output_limit: u64,
    /// The thread's own output cap, when one is set.
    pub max_output_tokens: Option<u64>,
    /// Whether a provider session exists — that is, whether `used_tokens`
    /// describes history the next send will actually carry.
    pub has_session: bool,
}

type ModelCache = HashMap<String, (Instant, Vec<ModelInfo>)>;

/// Model catalogs keyed by provider binary. Mirrors the codex provider's
/// `MODEL_CACHE`: providers are rebuilt per request, so the cache lives in
/// the module rather than on the provider instance.
static MODEL_CACHE: Lazy<Mutex<ModelCache>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// The catalog a thread's provider serves, cached briefly because listing
/// may spawn the provider binary. `None` when the lookup fails.
async fn model_catalog(
    state: &AppState,
    user: &UserRow,
    provider_id: &str,
) -> Option<Vec<ModelInfo>> {
    let key = format!("{provider_id}|{}", user.command_for_provider(provider_id));
    if let Some((at, models)) = MODEL_CACHE.lock().unwrap().get(&key) {
        if at.elapsed() < MODEL_CACHE_TTL {
            return Some(models.clone());
        }
    }
    // Listing can spawn the provider binary (Codex's app-server waits up to
    // two minutes); bound it so a wedged CLI cannot stall a send. A failure
    // caches an empty catalog — an unknown model skips enforcement anyway.
    let fetched = tokio::time::timeout(
        Duration::from_secs(15),
        state.provider_for(user, provider_id).list_models(),
    )
    .await;
    let models = fetched.ok().and_then(|r| r.ok()).unwrap_or_default();
    MODEL_CACHE
        .lock()
        .unwrap()
        .insert(key, (Instant::now(), models.clone()));
    Some(models)
}

/// The `ModelInfo` for the thread's model, when the provider's catalog
/// knows it. An empty or unknown model means no limits to enforce.
pub(crate) async fn thread_model(
    state: &AppState,
    user: &UserRow,
    thread: &ThreadRow,
) -> Option<ModelInfo> {
    if thread.model.trim().is_empty() {
        return None;
    }
    model_catalog(state, user, &thread.provider_id)
        .await?
        .into_iter()
        .find(|m| m.id == thread.model)
}

/// Estimated tokens across the messages the provider session would see:
/// everything after the context-reset watermark. Zero when the thread has
/// no live provider session — the next send starts a fresh one that only
/// receives the new prompt.
pub(crate) async fn estimate_history_tokens(
    state: &AppState,
    thread: &ThreadRow,
) -> anyhow::Result<u64> {
    if thread.devin_session_id.is_none() {
        return Ok(0);
    }
    let rows = state
        .db
        .context_size_rows(&thread.id, thread.context_cleared_seq)
        .await?;
    Ok(rows
        .iter()
        .map(|(content, thinking, parts, attachments)| {
            tokens::estimate_message_tokens(
                *content as u64,
                *thinking as u64,
                *parts as u64,
                attachments,
            )
        })
        .sum())
}

/// Estimated tokens for the message about to be sent: the prompt the
/// provider will actually receive (reference blocks and mode prefix
/// included) plus the uploaded attachments.
pub(crate) fn estimate_send_input_tokens(state: &AppState, input: &SendInput) -> u64 {
    // The minted machine token is always `mc_` + 32 hex chars; a stand-in of
    // the same length keeps the estimate honest without minting one early.
    let machine_token = input.machine_token.as_deref().or_else(|| {
        (!input.machine_refs.is_empty()).then_some("mc_00000000000000000000000000000000")
    });
    let prompt = apply_interaction_mode_prefix(
        prompt_with_machine_refs(
            &prompt_with_thread_refs(
                &prompt_with_refs(&input.prompt, &input.context_refs),
                &input.thread_refs,
            ),
            &input.machine_refs,
            machine_token,
            &state.agent_base_url(),
        ),
        &input.mode,
    );
    tokens::estimate_send_tokens(&prompt, &input.attachments)
}

/// Reject the send when the estimated prompt would push the session over
/// the model's advertised context window. No-op when the window is unknown.
pub(crate) async fn check_context_budget(
    state: &AppState,
    user: &UserRow,
    thread: &ThreadRow,
    input: &SendInput,
) -> Result<(), Response> {
    let Some(model) = thread_model(state, user, thread).await else {
        return Ok(());
    };
    if model.max_context_tokens == 0 {
        return Ok(());
    }
    let history = estimate_history_tokens(state, thread).await.unwrap_or(0);
    let pending = estimate_send_input_tokens(state, input);
    let reserve = thread
        .max_output_tokens
        .and_then(|v| u64::try_from(v).ok())
        .filter(|v| *v > 0)
        .or_else(|| (model.max_output_tokens > 0).then_some(model.max_output_tokens))
        .unwrap_or(DEFAULT_OUTPUT_HEADROOM);
    if reserve >= model.max_context_tokens {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(ApiError::new(format!(
                "the output token cap ({reserve}) alone exceeds {}'s \
                 context window ({} tokens); lower the thread's max output \
                 tokens setting",
                model.label, model.max_context_tokens
            ))),
        )
            .into_response());
    }
    let total = history.saturating_add(pending).saturating_add(reserve);
    if total > model.max_context_tokens {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(ApiError::new(format!(
                "message too large for {}'s context window \
                 (~{pending} new + ~{history} history + {reserve} reserved \
                 > {} tokens); shorten it or reset the thread's context",
                model.label, model.max_context_tokens
            ))),
        )
            .into_response());
    }
    Ok(())
}

/// `GET /api/threads/:id/context` — the usage estimate the composer shows.
pub(super) async fn get_context(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    let used = match estimate_history_tokens(&state, &thread).await {
        Ok(v) => v,
        Err(e) => return map_err_internal(e).into_response(),
    };
    let model = thread_model(&state, &user, &thread).await;
    Json(ContextUsageOut {
        used_tokens: used,
        context_limit: model.as_ref().map(|m| m.max_context_tokens).unwrap_or(0),
        output_limit: model.as_ref().map(|m| m.max_output_tokens).unwrap_or(0),
        max_output_tokens: thread.max_output_tokens.and_then(|v| u64::try_from(v).ok()),
        has_session: thread.devin_session_id.is_some(),
    })
    .into_response()
}

/// `POST /api/threads/:id/context/reset` — drop the provider session and
/// move the usage watermark to now. The next send starts a fresh session.
pub(super) async fn reset_context(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    // Finished runs stay in the runner for a retention window, so the check
    // has to look at the status rather than presence.
    if let Some(run) = state.thread_runner.get(&id).await {
        if *run.status.read().await == crate::thread_runner::RunStatus::Running {
            return (
                StatusCode::CONFLICT,
                Json(ApiError::new("cannot reset context while a run is active")),
            )
                .into_response();
        }
    }
    match state.db.reset_thread_context(&id, user.id).await {
        Ok(0) => (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response(),
        Ok(_) => Json(serde_json::json!({"ok": true})).into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::Attachment;

    fn input(prompt: &str) -> SendInput {
        SendInput {
            prompt: prompt.into(),
            mode: "code".into(),
            attachments: Vec::new(),
            att_meta: Vec::new(),
            client_message_id: None,
            context_paths: Vec::new(),
            context_refs: Vec::new(),
            referenced_thread_ids: Vec::new(),
            thread_refs: Vec::new(),
            machine_ids: Vec::new(),
            machine_refs: Vec::new(),
            machine_token: None,
        }
    }

    #[test]
    fn send_estimate_includes_mode_suffix() {
        // The code-mode plan hint is appended to every provider prompt, so
        // the estimate must be larger than the raw text alone.
        let stateless = tokens::estimate_send_tokens("hello", &[]);
        let estimated = {
            // estimate_send_input_tokens needs AppState; compare against the
            // composed prompt directly instead.
            let composed = apply_interaction_mode_prefix("hello".to_string(), "code");
            tokens::estimate_send_tokens(&composed, &[])
        };
        assert!(estimated > stateless);
    }

    #[test]
    fn send_estimate_counts_attachment_bytes_for_text() {
        let mut i = input("hi");
        i.attachments.push(Attachment {
            filename: "log.txt".into(),
            mime: "text/plain".into(),
            data: vec![b'x'; 4000],
        });
        let composed = apply_interaction_mode_prefix(i.prompt.clone(), &i.mode);
        let tokens_est = tokens::estimate_send_tokens(&composed, &i.attachments);
        // 4000 text chars ≈ 1000 tokens plus wrapper and mode suffix.
        assert!(tokens_est > 1000);
    }
}
