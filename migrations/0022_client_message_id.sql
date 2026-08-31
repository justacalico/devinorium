-- Devinorium schema migration 0022 — client-generated message id.
--
-- Lets the frontend generate a message id before sending so it can render the
-- message optimistically and remove it once the server echoes the same id.

ALTER TABLE messages ADD COLUMN client_message_id TEXT;

CREATE INDEX IF NOT EXISTS idx_messages_thread_client ON messages (thread_id, client_message_id);

-- Prevent duplicate client ids within a thread so retries/replays cannot create
-- multiple copies of the same optimistic message.
CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_thread_client_unique
ON messages (thread_id, client_message_id)
WHERE client_message_id IS NOT NULL;
