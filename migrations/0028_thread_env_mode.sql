-- Devinorium schema migration 0028 — Thread environment mode.
--
-- Threads can now be created in "worktree" mode, which auto-creates a
-- dedicated git worktree on the first send instead of using the main
-- worktree.

ALTER TABLE threads ADD COLUMN env_mode TEXT NOT NULL DEFAULT 'local' CHECK (env_mode IN ('local', 'worktree'));
