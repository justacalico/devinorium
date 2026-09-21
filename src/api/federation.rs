//! Federation routes: satellite registration, the node list, and removal.
//!
//! `register` sits outside session auth on purpose — a satellite has no
//! user account on the hub, it authenticates with the shared federation
//! token instead. Everything else in this module is owner-only: a proxied
//! call runs as the satellite's `local` owner, so letting a non-owner hub
//! user reach it would hand them owner-level access to another machine.

use axum::extract::{FromRequest, Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::{extract_bearer_token, CurrentUser};
use crate::db::federation_nodes::FederationNodeRow;
use crate::federation::{clean_node_base_url, ONLINE_WINDOW};
use crate::AppState;

const MAX_NODE_ID_LEN: usize = 64;
const MAX_NODE_NAME_LEN: usize = 128;
const MAX_VERSION_LEN: usize = 64;

/// Routes that authenticate with the federation token, not a session.
pub fn public_router() -> Router<AppState> {
    Router::new().route("/api/federation/register", post(register))
}

/// Session-authenticated routes; the handlers still gate on `is_owner`.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/federation/nodes", get(list_nodes))
        .route("/api/federation/nodes/:id", delete(remove_node))
        .route(
            "/api/federation/nodes/:id/proxy",
            axum::routing::any(super::federation_proxy::proxy),
        )
        .route(
            "/api/federation/nodes/:id/proxy/*path",
            axum::routing::any(super::federation_proxy::proxy),
        )
}

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response()
}

fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(ApiError::new("not found"))).into_response()
}

fn bad_request(msg: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(ApiError::new(msg.to_string())),
    )
        .into_response()
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(ApiError::new("invalid token")),
    )
        .into_response()
}

/// Whether the request carries the configured federation token. When no
/// token is configured the federation endpoints stay closed entirely.
fn has_federation_token(state: &AppState, req: &axum::extract::Request) -> bool {
    let Some(expected) = state.config.federation_token.as_deref() else {
        return false;
    };
    let Some(token) = extract_bearer_token(req) else {
        return false;
    };
    constant_time_eq::constant_time_eq(token.as_bytes(), expected.as_bytes())
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    id: String,
    name: String,
    base_url: String,
    #[serde(default)]
    version: String,
}

#[derive(Debug, Serialize)]
struct RegisterResponse {
    ok: bool,
    hub: String,
}

/// A satellite announcing itself. Doubles as the heartbeat: the node calls
/// it every [`crate::federation::HEARTBEAT_INTERVAL`] and `last_seen_at`
/// drives the online flag.
async fn register(State(state): State<AppState>, req: axum::extract::Request) -> Response {
    if !has_federation_token(&state, &req) {
        return unauthorized();
    }
    let Ok(Json(body)) = Json::<RegisterRequest>::from_request(req, &state).await else {
        return bad_request("invalid registration");
    };

    let id = body.id.trim();
    let name = body.name.trim();
    if id.is_empty()
        || id.len() > MAX_NODE_ID_LEN
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return bad_request("invalid id");
    }
    if name.is_empty()
        || name.chars().count() > MAX_NODE_NAME_LEN
        || name.chars().any(|c| c.is_control())
    {
        return bad_request("invalid name");
    }
    let version = body.version.trim();
    if version.chars().count() > MAX_VERSION_LEN || version.chars().any(|c| c.is_control()) {
        return bad_request("invalid version");
    }
    let base_url = match clean_node_base_url(&body.base_url) {
        Some(u) => u,
        None => return bad_request("invalid base_url"),
    };

    // Audit only the first sighting; the 30s heartbeat re-registers forever
    // and would otherwise drown the log.
    let is_new = matches!(state.db.get_federation_node(id).await, Ok(None));
    match state
        .db
        .upsert_federation_node(id, name, &base_url, version)
        .await
    {
        Ok(node) => {
            tracing::info!(node = %node.name, base_url = %node.base_url, "federation node registered");
            if is_new {
                let _ = state
                    .db
                    .audit(
                        None,
                        "federation.register",
                        &serde_json::json!({"node_id": id, "name": name, "base_url": base_url}),
                        None,
                    )
                    .await;
            }
            Json(RegisterResponse {
                ok: true,
                hub: state.config.display_node_name(),
            })
            .into_response()
        }
        Err(e) => map_err_internal(e).into_response(),
    }
}

/// Node as reported to the UI. `online` is computed from the last
/// heartbeat rather than probed on read so listing stays cheap.
#[derive(Debug, Serialize)]
pub struct NodeOut {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub version: String,
    pub online: bool,
    pub last_seen_at: String,
}

impl From<FederationNodeRow> for NodeOut {
    fn from(n: FederationNodeRow) -> Self {
        // Negative age means the hub clock moved backwards since the last
        // heartbeat; count it as fresh within the same window either way.
        let online = chrono::DateTime::parse_from_rfc3339(&n.last_seen_at)
            .map(|t| {
                let secs = chrono::Utc::now()
                    .signed_duration_since(t.with_timezone(&chrono::Utc))
                    .num_seconds();
                secs.unsigned_abs() <= ONLINE_WINDOW.as_secs()
            })
            .unwrap_or(false);
        Self {
            id: n.id,
            name: n.name,
            base_url: n.base_url,
            version: n.version,
            online,
            last_seen_at: n.last_seen_at,
        }
    }
}

#[derive(Debug, Serialize)]
struct NodesResponse {
    #[serde(rename = "self")]
    self_node: SelfNode,
    nodes: Vec<NodeOut>,
}

#[derive(Debug, Serialize)]
struct SelfNode {
    name: String,
    version: String,
}

async fn list_nodes(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    match state.db.list_federation_nodes().await {
        Ok(nodes) => Json(NodesResponse {
            self_node: SelfNode {
                name: state.config.display_node_name(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
            nodes: nodes.into_iter().map(NodeOut::from).collect(),
        })
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}

async fn remove_node(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(id): Path<String>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    match state.db.delete_federation_node(&id).await {
        Ok(true) => {
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "federation.remove_node",
                    &serde_json::json!({"node_id": id}),
                    None,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(false) => not_found(),
        Err(e) => map_err_internal(e).into_response(),
    }
}
