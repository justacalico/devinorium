-- Owner-configured root directory for cloned repositories.
-- NULL means the clone destination has not been configured yet.

ALTER TABLE users ADD COLUMN clone_root TEXT;
