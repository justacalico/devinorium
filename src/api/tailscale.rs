//! Tailscale status and serve-toggle routes.
//!
//! Mirrors t3code's endpoint provider add-on: `GET /api/tailscale` reports
//! the node's tailnet identity and every address the backend is reachable on
//! (tailnet IPs, MagicDNS HTTP, MagicDNS HTTPS via `tailscale serve`), and
//! `PUT /api/tailscale/serve` flips the `tailscale serve` mapping for owners.
//!
//! Bundled local mode refuses the toggle: the desktop app's server binds to
//! loopback and must not be republished onto a tailnet.

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, put, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::ApiError;
use crate::auth::session::CurrentUser;
use crate::tailscale::{self, TailscaleError};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/tailscale", get(status))
        .route("/api/tailscale/serve", put(set_serve))
}

/// One address the backend can be reached at, like t3code's
/// `AdvertisedEndpoint`.
#[derive(Debug, Serialize)]
struct EndpointInfo {
    /// `tailnet-ip`, `magicdns`, or `tailscale-https`.
    kind: &'static str,
    label: &'static str,
    url: String,
    /// False when the URL exists but the current bind cannot answer it
    /// (e.g. a tailnet-IP URL while bound to loopback).
    reachable: bool,
}

#[derive(Debug, Serialize)]
struct TailscaleInfo {
    /// True on the bundled desktop server; the feature is disabled there.
    local_mode: bool,
    /// The `tailscale` binary resolved and ran.
    installed: bool,
    /// `BackendState` from `tailscale status --json` (`Running`, ...).
    backend_state: Option<String>,
    magic_dns_name: Option<String>,
    tailnet_ipv4: Vec<String>,
    serve_enabled: bool,
    /// Tailnet-side HTTPS port the serve mapping uses.
    serve_port: u16,
    /// `https://<magicdns>/` URL when serve is enabled.
    https_url: Option<String>,
    /// Probe result for `https_url`; `None` when not probed.
    https_reachable: Option<bool>,
    endpoints: Vec<EndpointInfo>,
}

fn empty_info(local_mode: bool, serve_port: u16, installed: bool) -> TailscaleInfo {
    TailscaleInfo {
        local_mode,
        installed,
        backend_state: None,
        magic_dns_name: None,
        tailnet_ipv4: vec![],
        serve_enabled: false,
        serve_port,
        https_url: None,
        https_reachable: None,
        endpoints: vec![],
    }
}

async fn build_info(state: &AppState) -> TailscaleInfo {
    let cfg = &state.config;
    let serve_port = cfg.tailscale_serve_port;
    if cfg.is_local_mode() {
        return empty_info(true, serve_port, false);
    }
    let status = match state.tailscale.read_status().await {
        Ok(s) => s,
        Err(TailscaleError::NotInstalled) => return empty_info(false, serve_port, false),
        Err(e) => {
            tracing::debug!("tailscale status failed: {e}");
            return empty_info(false, serve_port, true);
        }
    };

    let serve_enabled = state.tailscale.serve_enabled(&cfg.host, cfg.port).await;
    let https_url = if serve_enabled {
        status
            .magic_dns_name
            .as_deref()
            .map(|dns| tailscale::build_https_base_url(dns, serve_port))
    } else {
        None
    };
    let https_reachable = match &https_url {
        Some(url) => Some(state.tailscale.probe_https(url).await),
        None => None,
    };

    // Tailnet HTTP URLs only answer when the bind covers the tailnet
    // interface: a wildcard bind or the tailscale IP itself.
    let bare_host = cfg.host.trim_start_matches('[').trim_end_matches(']');
    let bound_ip = bare_host.parse::<std::net::IpAddr>().ok();
    let lan_reachable = bound_ip
        .map(|ip| ip.is_unspecified() || status.tailnet_ipv4.iter().any(|t| t == &bare_host))
        .unwrap_or(false);

    let mut endpoints = Vec::new();
    for ip in &status.tailnet_ipv4 {
        endpoints.push(EndpointInfo {
            kind: "tailnet-ip",
            label: "Tailnet IP",
            url: format!("http://{ip}:{}", cfg.port),
            reachable: lan_reachable,
        });
    }
    if let Some(dns) = &status.magic_dns_name {
        endpoints.push(EndpointInfo {
            kind: "magicdns",
            label: "MagicDNS",
            url: format!("http://{dns}:{}", cfg.port),
            reachable: lan_reachable,
        });
    }
    if let Some(url) = &https_url {
        endpoints.push(EndpointInfo {
            kind: "tailscale-https",
            label: "Tailscale HTTPS",
            url: url.clone(),
            reachable: https_reachable.unwrap_or(false),
        });
    }

    TailscaleInfo {
        local_mode: false,
        installed: true,
        backend_state: status.backend_state,
        magic_dns_name: status.magic_dns_name,
        tailnet_ipv4: status.tailnet_ipv4,
        serve_enabled,
        serve_port,
        https_url,
        https_reachable,
        endpoints,
    }
}

async fn status(State(state): State<AppState>, CurrentUser(_user): CurrentUser) -> Response {
    Json(build_info(&state).await).into_response()
}

#[derive(Debug, Deserialize)]
struct SetServeRequest {
    enabled: bool,
    /// Tailnet-side HTTPS port; defaults to the configured serve port.
    port: Option<u16>,
}

async fn set_serve(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Json(req): Json<SetServeRequest>,
) -> Response {
    if !user.is_owner {
        return (StatusCode::FORBIDDEN, Json(ApiError::new("forbidden"))).into_response();
    }
    if state.config.is_local_mode() {
        return (
            StatusCode::CONFLICT,
            Json(ApiError::new(
                "tailscale is not available on the bundled server",
            )),
        )
            .into_response();
    }

    let ts_status = match state.tailscale.read_status().await {
        Ok(s) => s,
        Err(TailscaleError::NotInstalled) => {
            return (
                StatusCode::NOT_FOUND,
                Json(ApiError::new("tailscale CLI is not installed")),
            )
                .into_response();
        }
        Err(e) => {
            return (StatusCode::BAD_GATEWAY, Json(ApiError::new(e.to_string()))).into_response();
        }
    };

    let serve_port = req.port.unwrap_or(state.config.tailscale_serve_port);
    if req.enabled {
        if ts_status.magic_dns_name.is_none() {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiError::new(
                    "MagicDNS is not available; log in to Tailscale and enable MagicDNS on the tailnet",
                )),
            )
                .into_response();
        }
        let target = tailscale::local_serve_target(&state.config.host, state.config.port);
        if let Err(e) = state.tailscale.ensure_serve(&target, serve_port).await {
            return (StatusCode::BAD_GATEWAY, Json(ApiError::new(e.to_string()))).into_response();
        }
        tracing::info!(%target, serve_port, user_id = user.id, "tailscale serve enabled");
    } else if let Err(e) = state.tailscale.disable_serve(serve_port).await {
        return (StatusCode::BAD_GATEWAY, Json(ApiError::new(e.to_string()))).into_response();
    }

    let _ = state
        .db
        .audit(
            Some(user.id),
            "tailscale.serve",
            &serde_json::json!({"enabled": req.enabled, "port": serve_port}),
            None,
        )
        .await;

    Json(build_info(&state).await).into_response()
}
