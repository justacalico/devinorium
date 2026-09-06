-- Migration 0024 — record which AI provider a thread uses.
--
-- The provider is chosen when the thread is created (or while it has not yet
-- started a provider session) and is then locked in, since the session id on
-- the row only has meaning to the provider that created it.

ALTER TABLE threads ADD COLUMN provider_id TEXT NOT NULL DEFAULT 'devin-cli';
