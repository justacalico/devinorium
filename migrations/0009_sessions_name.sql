-- Devinorium schema migration 0009
-- Add an optional display name to sessions so the devices UI can label
-- paired devices and browser sessions.

ALTER TABLE sessions ADD COLUMN name TEXT;
