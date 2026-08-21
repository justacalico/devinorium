-- Devinorium schema migration 0016 — project type detection.
--
-- Stores the detected project type (e.g. "flutter", "rust", "node") so the
-- frontend can render the correct framework icon without re-scanning the
-- filesystem on every load. The type is detected once at creation time and
-- can be re-detected on demand.

ALTER TABLE projects ADD COLUMN project_type TEXT NOT NULL DEFAULT 'generic';
