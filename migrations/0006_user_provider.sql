-- Migration 0006 — add per-user default AI provider.
--
-- Devinorium supports multiple AI providers. This column records the user's
-- preferred provider; today only `devin-cli` is available.

ALTER TABLE users ADD COLUMN provider_id TEXT NOT NULL DEFAULT 'devin-cli';
