-- Devinorium schema migration 0003 — introduce projects.
--
-- Projects are filesystem-backed working directories. Each project has a
-- validated path (constrained to the configured file root) and contains
-- its own threads. The Devin CLI uses the project path as its working
-- directory, and the file manager scopes operations to the active project.
--
-- The old `workspaces` table is dropped; `thread_groups` remain as optional
-- visual sub-containers within a project.

-- Drop the deprecated workspaces table and its orphaned data.
-- First remove the orphaned foreign-key column on threads so the table drop
-- does not break future INSERTs.
ALTER TABLE threads DROP COLUMN workspace_id;
DROP TABLE IF EXISTS workspaces;

-- Add project_id to threads. The old workspace_id column, if present, is
-- ignored by the application from now on.
ALTER TABLE threads ADD COLUMN project_id INTEGER;

CREATE INDEX IF NOT EXISTS idx_threads_project ON threads(project_id, updated_at DESC);

-- Projects table.
CREATE TABLE IF NOT EXISTS projects (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    path        TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (user_id, name),
    UNIQUE (user_id, path)
);

CREATE INDEX IF NOT EXISTS idx_projects_user ON projects(user_id, name);
