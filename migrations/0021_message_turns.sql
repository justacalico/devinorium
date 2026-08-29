-- Devinorium schema migration 0021 — message turns, event sequence, and counts.
--
-- Adds turn-based grouping and a per-thread event sequence so the message API
-- can paginate by user-anchored turns and apply deltas by sequence number.

ALTER TABLE messages ADD COLUMN turn_id INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN content_length INTEGER GENERATED ALWAYS AS (length(content)) VIRTUAL;
ALTER TABLE messages ADD COLUMN parts_length INTEGER GENERATED ALWAYS AS (length(parts)) VIRTUAL;

-- Backfill sequence numbers from the existing message id.
UPDATE messages SET seq = id;

-- Backfill turn numbers: each user message starts a new turn; non-user
-- messages that follow inherit the same turn until the next user message.
UPDATE messages
SET turn_id = (
    SELECT turn
    FROM (
        SELECT
            id,
            SUM(CASE WHEN role = 'user' THEN 1 ELSE 0 END)
                OVER (PARTITION BY thread_id ORDER BY id) AS turn
        FROM messages
    ) AS turns
    WHERE turns.id = messages.id
);

-- Add turn/sequence indexes. Keep the existing (thread_id, id) index.
CREATE INDEX IF NOT EXISTS idx_messages_thread_turn_id ON messages (thread_id, turn_id, id);
CREATE INDEX IF NOT EXISTS idx_messages_thread_created_turn ON messages (thread_id, created_at, turn_id);
CREATE INDEX IF NOT EXISTS idx_messages_thread_seq ON messages (thread_id, seq);
