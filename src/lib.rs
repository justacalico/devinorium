//! Devinorium library crate — a secure, self-hostable Material 3 web UI for
//! the Devin CLI.
//!
//! The binary target (`src/main.rs`) is a thin wrapper around this library.

pub mod auth;
pub mod config;
pub mod db;
pub mod providers;

use std::sync::Arc;

/// Shared application state passed to all axum handlers.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
    pub provider: Arc<dyn providers::Provider>,
}
