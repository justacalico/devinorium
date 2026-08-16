-- Devinorium schema migration 0012 — Git branch and worktree tracking.
--
-- Threads can be pinned to a specific branch and a checked-out worktree,
-- so the runner uses the right working directory and the UI can show
-- per-thread Git context.

ALTER TABLE threads ADD COLUMN branch TEXT;
ALTER TABLE threads ADD COLUMN worktree_path TEXT;
