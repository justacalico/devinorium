-- Migration 0008 — owner-managed accounts, remove invite tokens.
--
-- Registration is no longer invite-based. The first user created on a fresh
-- install is marked as owner and can create further accounts directly.

PRAGMA foreign_keys = OFF;
DROP TABLE IF EXISTS invite_tokens;
PRAGMA foreign_keys = ON;

ALTER TABLE users ADD COLUMN is_owner INTEGER NOT NULL DEFAULT 0;

-- Existing deployments: mark the first user as owner. On fresh installs this
-- is a no-op and the bootstrap logic will set the flag for the first account.
UPDATE users SET is_owner = 1 WHERE id = (SELECT MIN(id) FROM users);

CREATE INDEX IF NOT EXISTS idx_users_is_owner ON users(is_owner);
