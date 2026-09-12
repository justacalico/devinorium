-- Devinorium schema migration 0030 — message attachment blobs.
--
-- Files uploaded with a user message are stored here so clients can render
-- thumbnails and fetch the original bytes after the turn completes. `idx`
-- matches the attachment's position in the message's `attachments` JSON
-- metadata array.

CREATE TABLE IF NOT EXISTS message_attachments (
    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    filename   TEXT NOT NULL,
    mime       TEXT NOT NULL,
    data       BLOB NOT NULL,
    PRIMARY KEY (message_id, idx)
);
