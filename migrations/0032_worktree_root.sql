-- Owner-configured root directory for managed worktrees.
-- `~` expands to the server's home directory at use time, so existing
-- servers keep creating worktrees under the home directory.

ALTER TABLE users ADD COLUMN worktree_root TEXT NOT NULL DEFAULT '~';
