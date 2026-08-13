-- Add a public device identifier so device lists can be returned and revoked
-- without exposing the full session token.
ALTER TABLE sessions ADD COLUMN device_id TEXT;

UPDATE sessions SET device_id = lower(hex(randomblob(8))) WHERE device_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_device_id ON sessions(device_id);
