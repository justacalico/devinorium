-- Plans / todos for threads.

CREATE TABLE IF NOT EXISTS plans (
    id          TEXT PRIMARY KEY,
    thread_id   TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    run_id      TEXT,
    explanation TEXT,
    steps       TEXT NOT NULL DEFAULT '[]',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (thread_id, run_id)
);

CREATE INDEX IF NOT EXISTS idx_plans_thread ON plans(thread_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_plans_thread_run ON plans(thread_id, run_id);
