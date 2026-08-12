-- Migration 0007 — add per-user provider CLI command.
--
-- Each user can configure the binary used by their selected provider.
-- Today this only applies to the Devin CLI provider.

ALTER TABLE users ADD COLUMN provider_command TEXT NOT NULL DEFAULT 'devin';
