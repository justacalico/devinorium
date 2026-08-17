-- Migration 0015 — device_id should be unique per user, not globally.
--
-- The previous index prevented two different users from sharing the same
-- random device_id. That's unnecessarily restrictive and can fail with
-- large numbers of devices. Replace it with a composite (user_id, device_id)
-- unique index.

DROP INDEX IF EXISTS idx_sessions_device_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_device_id ON sessions(user_id, device_id);
