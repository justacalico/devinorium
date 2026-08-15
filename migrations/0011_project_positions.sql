-- Devinorium schema migration 0011 — per-account project ordering.
--
-- Adds an explicit position column so users can reorder projects in the
-- sidebar. Existing projects keep a stable order based on creation id.

ALTER TABLE projects ADD COLUMN position INTEGER NOT NULL DEFAULT 0;

-- Back-fill existing projects so their relative order is preserved.
UPDATE projects SET position = id;

-- Index for listing projects in the user's chosen order.
CREATE INDEX IF NOT EXISTS idx_projects_user_position ON projects(user_id, position, id);
