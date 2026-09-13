-- Devinorium schema migration 0033 — project groups.
--
-- Project groups organize the sidebar project list: a project can belong to
-- at most one group (group_id NULL = ungrouped), and the sidebar filter
-- dropdown shows every project when "All" is selected.

CREATE TABLE IF NOT EXISTS project_groups (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (user_id, name)
);

CREATE INDEX IF NOT EXISTS idx_project_groups_user ON project_groups(user_id, position);

-- Nullable group reference on projects; deleting a group ungroups its
-- projects instead of removing them.
ALTER TABLE projects ADD COLUMN group_id INTEGER REFERENCES project_groups(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_projects_group ON projects(group_id);
