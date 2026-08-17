-- Migration 0014 — enforce referential integrity on threads.project_id.
--
-- threads.project_id was added without a foreign key in migration 0003.
-- This could leave orphaned project references and allowed project rows to
-- be deleted while threads still pointed at them. Add the missing FK with
-- CASCADE so deleting a project removes its threads.
--
-- Any threads whose project_id does not refer to an existing project are
-- removed; they were already inaccessible because the project was gone.

DELETE FROM threads WHERE project_id IS NOT NULL AND project_id NOT IN (SELECT id FROM projects);

-- Drop the existing index on the column while we re-create it.
DROP INDEX IF EXISTS idx_threads_project;

-- Add a new column with the correct foreign key.
ALTER TABLE threads ADD COLUMN project_id_new INTEGER REFERENCES projects(id) ON DELETE CASCADE;

-- Copy values from the old column.
UPDATE threads SET project_id_new = project_id;

-- Drop the old column.
ALTER TABLE threads DROP COLUMN project_id;

-- Rename the new column back.
ALTER TABLE threads RENAME COLUMN project_id_new TO project_id;

-- Re-create the project index.
CREATE INDEX IF NOT EXISTS idx_threads_project ON threads(project_id, updated_at DESC);
