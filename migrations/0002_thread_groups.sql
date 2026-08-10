-- Devinorium schema migration 0002 — replace workspaces with thread groups.
--
-- Thread groups are lightweight visual containers for organizing threads in
-- the sidebar. They have no filesystem path (unlike workspaces). Threads can
-- be ungrouped (thread_group_id = NULL) or belong to a single group.

CREATE TABLE IF NOT EXISTS thread_groups (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL DEFAULT 'New Group',
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (user_id, name)
);

CREATE INDEX IF NOT EXISTS idx_thread_groups_user ON thread_groups(user_id, position);

-- Add thread_group_id column to threads (nullable = ungrouped).
ALTER TABLE threads ADD COLUMN thread_group_id INTEGER REFERENCES thread_groups(id) ON DELETE SET NULL;

-- Migrate existing workspace references: no migration needed, workspaces
-- are being removed entirely. Old workspace_id column stays in the table
-- but is no longer used by the application.

CREATE INDEX IF NOT EXISTS idx_threads_group ON threads(thread_group_id);
