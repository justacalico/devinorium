-- Devinorium schema migration 0035 — machines.
--
-- Owner-managed VNC machines that AI threads can remote-control. Rows are
-- server-wide: every signed-in user can list and reference them, only the
-- owner can change them. `password` is the VNC auth secret and is never
-- returned by the machine list API.

CREATE TABLE machines (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    host       TEXT NOT NULL,
    port       INTEGER NOT NULL DEFAULT 5900,
    password   TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
