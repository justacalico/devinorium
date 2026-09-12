-- Devinorium schema migration 0031 — Instance-level server settings.
--
-- Key/value rows for settings the owner manages through the UI that must
-- survive restarts without an env file, e.g. the Tailscale serve toggle
-- and its tailnet-side HTTPS port.

CREATE TABLE server_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
