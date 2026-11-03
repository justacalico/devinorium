-- Devinorium schema migration 0047 — Public thread shares.
--
-- Sharing a thread publishes a point-in-time snapshot of its transcript at
-- an unguessable /shared/<id> URL, no login required. One share per thread;
-- re-sharing refreshes the snapshot in place and deleting the thread or the
-- share revokes public access.

CREATE TABLE IF NOT EXISTS thread_shares (
    id          TEXT PRIMARY KEY,
    thread_id   TEXT NOT NULL UNIQUE REFERENCES threads(id) ON DELETE CASCADE,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    snapshot    TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_thread_shares_thread ON thread_shares(thread_id);
