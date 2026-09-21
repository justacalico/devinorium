-- Devinorium schema migration 0036 — federation nodes.
--
-- Satellite backends that registered with this hub. `id` is the node's own
-- stable identifier (a UUID it persists in its server_settings), so a
-- satellite re-registers onto the same row and moves of address only
-- refresh `base_url`. `last_seen_at` drives the online flag: nodes that
-- stop heartbeating stay listed but report offline.

CREATE TABLE federation_nodes (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    base_url     TEXT NOT NULL,
    version      TEXT NOT NULL DEFAULT '',
    last_seen_at TEXT NOT NULL,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
