-- Devinorium schema migration 0004 — add per-thread permission rules.
--
-- Threads already store a permission_mode. This adds an optional free-form
-- allowlist so users can grant specific tool scopes (e.g. Exec(curl),
-- Fetch(**), Read(src/**)) without enabling full bypass.

ALTER TABLE threads ADD COLUMN permissions TEXT;
