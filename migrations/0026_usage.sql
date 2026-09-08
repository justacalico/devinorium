-- Devinorium schema migration 0026 — provider usage tracking.
--
-- `usage_events` stores one row per prompt turn with the *delta* of the
-- cumulative counters the agent reported, so it can be aggregated by day,
-- provider, and model. `usage_sessions` keeps the last cumulative snapshot
-- per provider session so the next turn can be diffed against it.

CREATE TABLE IF NOT EXISTS usage_events (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    thread_id           TEXT NOT NULL,
    provider_id         TEXT NOT NULL,
    session_id          TEXT,
    model               TEXT NOT NULL,
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    thought_tokens      INTEGER NOT NULL DEFAULT 0,
    cached_read_tokens  INTEGER NOT NULL DEFAULT 0,
    cached_write_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens        INTEGER NOT NULL DEFAULT 0,
    cost_amount         REAL,
    cost_currency       TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Last cumulative usage snapshot seen for a provider session. Used to turn
-- the session-total counters agents report into per-turn deltas. Keyed by
-- (user, provider, session) because provider session ids are not globally
-- unique.
CREATE TABLE IF NOT EXISTS usage_sessions (
    user_id             INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider_id         TEXT NOT NULL,
    session_id          TEXT NOT NULL,
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    thought_tokens      INTEGER NOT NULL DEFAULT 0,
    cached_read_tokens  INTEGER NOT NULL DEFAULT 0,
    cached_write_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens        INTEGER NOT NULL DEFAULT 0,
    cost_amount         REAL,
    cost_currency       TEXT,
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY (user_id, provider_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_usage_events_user_created ON usage_events(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_usage_events_thread ON usage_events(thread_id);
