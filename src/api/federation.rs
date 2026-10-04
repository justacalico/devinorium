//! Federation routes: pairing satellites and managing the node list.
//!
//! All routes are owner-only: a paired node is a remote shell on another
//! machine, and the node token is as sensitive as an owner session.
//!
//! There is no satellite-initiated registration: a satellite stays dumb and
//! just answers `/api/node/*`. The hub pairs by calling the satellite's
//! `info` and `pair` endpoints with the code the satellite printed, then
//! stores the returned credential against the node row.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::{map_err_internal, ApiError};
use crate::auth::session::CurrentUser;
use crate::db::federation_nodes::FederationNodeRow;
use crate::federation::{clean_node_base_url, ONLINE_WINDOW};
use crate::node_client::NodeClient;
use crate::AppState;

const MAX_NODE_NAME_LEN: usize = 128;

/// Strip control characters and clamp a satellite-supplied string.
fn clamp_node_string(s: &str, max: usize) -> String {
    s.chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect::<String>()
        .trim()
        .to_string()
}

/// Node management routes; every handler still gates on `is_owner`.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/federation/nodes", get(list_nodes))
        .route("/api/federation/nodes/pair", post(pair_node))
        .route("/api/federation/nodes/:id", delete(remove_node))
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

fn bad_gateway(msg: impl Into<String>) -> Response {
    (StatusCode::BAD_GATEWAY, Json(ApiError::new(msg.into()))).into_response()
}

/// Node as reported to the UI. `online` reflects the last successful probe.
#[derive(Debug, Serialize)]
pub struct NodeOut {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub version: String,
    pub online: bool,
    pub last_seen_at: String,
}

impl NodeOut {
    fn from_row(n: FederationNodeRow, online: bool) -> Self {
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

/// Whether a stored `last_seen_at` is fresh enough to still mean online.
fn last_seen_fresh(last_seen_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(last_seen_at)
        .map(|t| {
            let secs = chrono::Utc::now()
                .signed_duration_since(t.with_timezone(&chrono::Utc))
                .num_seconds();
            secs.unsigned_abs() <= ONLINE_WINDOW.as_secs()
        })
        .unwrap_or(false)
}

/// Probe one node for liveness and refresh its row on success. Runs with a
/// short timeout so a dead node cannot stall the list.
async fn probe_node(state: AppState, node: FederationNodeRow) -> bool {
    let Some(client) = NodeClient::for_node_short(&state, &node) else {
        return false;
    };
    match client.info().await {
        Ok(info) => {
            state
                .db
                .touch_federation_node(
                    &node.id,
                    &clamp_node_string(&info.name, MAX_NODE_NAME_LEN),
                    &clamp_node_string(&info.version, 64),
                )
                .await;
            true
        }
        Err(_) => false,
    }
}

async fn list_nodes(State(state): State<AppState>, CurrentUser(user): CurrentUser) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    let nodes = match state.db.list_federation_nodes().await {
        Ok(n) => n,
        Err(e) => return map_err_internal(e).into_response(),
    };

    // Probe every node concurrently; a node that answered within the last
    // ONLINE_WINDOW counts as online without a fresh probe.
    let mut out = Vec::with_capacity(nodes.len());
    let mut probes = Vec::new();
    for node in nodes {
        if last_seen_fresh(&node.last_seen_at) {
            out.push(NodeOut::from_row(node, true));
        } else {
            probes.push(node);
        }
    }
    let results =
        futures::future::join_all(probes.iter().map(|n| probe_node(state.clone(), n.clone())))
            .await;
    for (node, online) in probes.into_iter().zip(results) {
        out.push(NodeOut::from_row(node, online));
    }

    Json(NodesResponse {
        self_node: SelfNode {
            name: state.config.display_node_name(),
            version: env!("CARGO_PKG_VERSION").to_string(),
        },
        nodes: out,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct PairNodeRequest {
    /// The satellite's base URL, e.g. `http://workstation:7878`.
    pub url: String,
    /// The code the satellite printed at startup.
    pub code: String,
    /// Optional display name override stored on the hub.
    #[serde(default)]
    pub name: Option<String>,
}

/// Pair with a satellite: verify it is one, exchange the code for a token,
/// and store the node. Re-pairing the same node id refreshes the row —
/// that is how a moved or renamed satellite heals.
async fn pair_node(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<PairNodeRequest>,
) -> Response {
    if !user.is_owner {
        return forbidden();
    }
    let Some(base_url) = clean_node_base_url(&req.url) else {
        return bad_request("invalid url");
    };
    if req.code.trim().is_empty() {
        return bad_request("pairing code is required");
    }
    if let Some(name) = req.name.as_deref() {
        if name.chars().count() > MAX_NODE_NAME_LEN || name.chars().any(|c| c.is_control()) {
            return bad_request("invalid name");
        }
    }

    let client = crate::federation::short_http_client();

    // Confirm the target is actually a satellite before sending the code,
    // so a wrong URL does not leak it to an arbitrary server.
    let info_url = format!("{base_url}/api/node/info");
    let info = match client.get(&info_url).send().await {
        Ok(resp) if resp.status().is_success() => {
            match resp.json::<crate::node::NodeInfo>().await {
                Ok(i) => i,
                Err(_) => return bad_request("target is not a devinorium satellite"),
            }
        }
        Ok(_) => return bad_request("target is not a devinorium satellite"),
        Err(_) => return bad_gateway("node unreachable"),
    };
    if !info.satellite {
        return bad_request("target is not running in satellite mode");
    }

    let pair = match NodeClient::pair(&client, &base_url, req.code.trim()).await {
        Ok(p) => p,
        Err(crate::node_client::NodeCallError::Remote { kind, message })
            if kind == "unauthorized" || kind == "rate_limited" || kind == "consumed" =>
        {
            return bad_request(&message);
        }
        Err(e) => return bad_gateway(format!("pairing failed: {e}")),
    };

    // The paired node's id must match the identity probe; a mismatch means
    // the URL serves different satellites behind info and pair.
    if pair.node_id != info.node_id {
        return bad_gateway("node identity mismatch between info and pair");
    }

    // Satellite-supplied strings get the same hygiene as user input:
    // length cap, no control characters.
    let pair_name = clamp_node_string(&pair.name, MAX_NODE_NAME_LEN);
    let version = clamp_node_string(&pair.version, 64);
    let name = req
        .name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or(pair_name);

    match state
        .db
        .upsert_federation_node(&pair.node_id, &name, &base_url, &version, &pair.token)
        .await
    {
        Ok(node) => {
            tracing::info!(node = %node.name, base_url = %node.base_url, "satellite node paired");
            let _ = state
                .db
                .audit(
                    Some(user.id),
                    "federation.pair",
                    &serde_json::json!({"node_id": pair.node_id, "name": name, "base_url": base_url}),
                    None,
                )
                .await;
            (StatusCode::CREATED, Json(NodeOut::from_row(node, true))).into_response()
        }
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
