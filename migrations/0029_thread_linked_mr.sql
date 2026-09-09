-- Devinorium schema migration 0029 — Thread linked merge request.
--
-- Threads can now have a merge request explicitly linked to them. The link
-- is stored as a JSON blob so the UI can render it without re-querying
-- GitLab on every thread view.

ALTER TABLE threads ADD COLUMN linked_mr TEXT;
