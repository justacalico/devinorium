//! `GET /api/threads/:id/skills` — the skills discoverable in the thread's
//! working directory, feeding the composer's `/` picker.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::AppState;

use super::plan::thread_target;

pub(super) async fn list_skills(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    let thread = match state.db.get_thread(&id, user.id).await {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response();
        }
        Err(e) => return map_err_internal(e).into_response(),
    };
    // The same directory the agent runs in, so the picker offers exactly the
    // project skills the provider can see (worktree mode included).
    let target = match thread_target(&state, &thread).await {
        Ok(t) => t,
        Err(e) => return map_err_internal(e).into_response(),
    };
    if let Some(node) = target.node {
        if !user.is_owner {
            return (
                StatusCode::FORBIDDEN,
                Json(ApiError::new("paired machines are owner-only")),
            )
                .into_response();
        }
        let Some(client) = crate::node_client::NodeClient::for_node(&state, &node) else {
            return crate::node_client::node_bad_gateway("node unreachable");
        };
        return match client
            .with_proxy_user(&user.username)
            .skills_list(&target.dir)
            .await
        {
            Ok(v) => Json(v).into_response(),
            Err(e) => crate::node_client::node_bad_gateway(e.to_string()),
        };
    }
    let skills = crate::skills::discover_skills(&target.dir, &state.config.home_dir).await;
    Json(serde_json::json!({
        "skills": skills.iter().map(|s| &s.info).collect::<Vec<_>>(),
    }))
    .into_response()
}
