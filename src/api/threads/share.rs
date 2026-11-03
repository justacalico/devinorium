//! Thread sharing endpoints.
//!
//! `POST` publishes a point-in-time snapshot of the thread's transcript at a
//! public `/shared/<id>` URL; `DELETE` revokes it. Re-sharing refreshes the
//! snapshot in place so the link stays stable — matching how `/share` and
//! `/unshare` behave in the provider CLIs that offer them (OpenCode,
//! Devin CLI).

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use uuid::Uuid;

use crate::api::map_err_internal;
use crate::auth::session::CurrentUser;
use crate::db::thread_shares::SharedMessage;
use crate::db::ThreadRow;
use crate::AppState;

use super::{MessageOut, ThreadOut};

/// Build the frozen transcript stored with a share.
fn snapshot_messages(rows: Vec<crate::db::MessageRow>) -> Vec<SharedMessage> {
    rows.into_iter()
        .map(|row| {
            let out = MessageOut::from(row);
            SharedMessage {
                role: out.role,
                content: out.content,
                thinking: out.thinking,
                parts: out.parts,
                attachments: out.attachments,
                model: out.model,
                created_at: out.created_at,
            }
        })
        .collect()
}

async fn owned_thread(state: &AppState, id: &str, user_id: i64) -> Option<ThreadRow> {
    state.db.get_thread(id, user_id).await.ok().flatten()
}

pub(super) async fn share(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    let Some(thread) = owned_thread(&state, &id, user.id).await else {
        return (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response();
    };

    let rows = match state.db.list_messages(&id).await {
        Ok(rows) => rows,
        Err(e) => return map_err_internal(e).into_response(),
    };
    let snapshot = match serde_json::to_string(&snapshot_messages(rows)) {
        Ok(s) => s,
        Err(e) => return map_err_internal(e).into_response(),
    };

    // Reuse the live share's id on a re-share; only mint a new one for a
    // first publish so existing links keep working.
    let share_id = match state.db.get_share_for_thread(&id).await {
        Ok(existing) => existing
            .map(|s| s.id)
            .unwrap_or_else(|| format!("sh-{}", Uuid::new_v4().simple())),
        Err(e) => return map_err_internal(e).into_response(),
    };

    if let Err(e) = state
        .db
        .upsert_thread_share(
            &share_id,
            &id,
            user.id,
            &thread.title,
            &thread.provider_id,
            &snapshot,
        )
        .await
    {
        return map_err_internal(e).into_response();
    }

    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => Json(ThreadOut::from(t)).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

pub(super) async fn unshare(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    if owned_thread(&state, &id, user.id).await.is_none() {
        return (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response();
    }

    if let Err(e) = state.db.delete_thread_share(&id, user.id).await {
        return map_err_internal(e).into_response();
    }

    match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => Json(ThreadOut::from(t)).into_response(),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(crate::api::ApiError::new("not found")),
        )
            .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::snapshot_messages;
    use crate::db::MessageRow;

    #[test]
    fn snapshot_keeps_renderable_fields_only() {
        let row = MessageRow {
            id: 7,
            thread_id: "th".into(),
            role: "assistant".into(),
            content: "hello".into(),
            thinking: Some("hmm".into()),
            parts: None,
            attachments: "[]".into(),
            model: "m".into(),
            client_message_id: Some("secret-client-id".into()),
            created_at: "2024-01-01T00:00:00Z".into(),
            turn_id: 3,
            seq: 9,
            content_length: 5,
            parts_length: None,
        };
        let msgs = snapshot_messages(vec![row]);
        assert_eq!(msgs.len(), 1);
        let json = serde_json::to_value(&msgs[0]).unwrap();
        assert_eq!(json["role"], "assistant");
        assert_eq!(json["content"], "hello");
        assert!(json.get("client_message_id").is_none());
        assert!(json.get("thread_id").is_none());
        assert!(json.get("seq").is_none());
    }
}
