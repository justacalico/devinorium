-- Devinorium schema migration 0043 — Thread viewed watermark.
--
-- `viewed_message_id` records the newest message id the user has seen.
-- Result messages (assistant or error rows) above the watermark mark the
-- thread as unread so the sidebar drops the "done" badge once the outcome
-- has been viewed. Opening a thread moves the watermark forward.

ALTER TABLE threads ADD COLUMN viewed_message_id INTEGER NOT NULL DEFAULT 0;
