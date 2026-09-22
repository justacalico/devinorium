-- Sessions are now stored by SHA-256(token) instead of the plaintext token.
-- Existing plaintext rows cannot be rehashed in SQL, so they are dropped;
-- every user signs in once after the upgrade.
DELETE FROM sessions;
