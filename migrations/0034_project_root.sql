-- Devinorium schema migration 0034 — project root.
--
-- Owner-configured parent directory that "Create new" project folders are
-- created under. `~` expands to the server's home directory at use time, so
-- existing servers keep creating projects under the home directory.

ALTER TABLE users ADD COLUMN project_root TEXT NOT NULL DEFAULT '~';
