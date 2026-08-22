-- Devinorium schema migration 0017 — pinned projects and threads.
--
-- Lets users pin projects and threads so they stick to the top of the sidebar
-- and survive reordering. Pinned items sort above unpinned ones; within each
-- group the existing order (position for projects, updated_at for threads) is
-- preserved.

ALTER TABLE projects ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1));
ALTER TABLE threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1));

CREATE INDEX idx_projects_pinned ON projects (user_id, pinned DESC, position ASC, id ASC);
CREATE INDEX idx_threads_pinned ON threads (user_id, pinned DESC, updated_at DESC);
CREATE INDEX idx_threads_project_pinned ON threads (user_id, project_id, pinned DESC, updated_at DESC);
