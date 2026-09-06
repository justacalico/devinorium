-- Migration 0025 — per-provider CLI commands.
--
-- `provider_command` only covers the user's default provider. Now that threads
-- can pick any provider, each provider needs its own command. The map is
-- populated lazily through the auth API; providers without an entry use their
-- built-in default command.

ALTER TABLE users ADD COLUMN provider_commands TEXT NOT NULL DEFAULT '{}';
