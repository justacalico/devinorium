//! Authentication subsystem.
//!
//! Full auth logic (password verification, TOTP, middleware) lives here.
//! This module currently exposes the token helper used by the db layer;
//! the rest is filled in by the auth merge request.

pub mod tokens;
