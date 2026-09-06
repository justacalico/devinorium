-- Track whether the thread title was set by the user so the first message
-- can safely derive a title from the prompt without overwriting a rename.
ALTER TABLE threads ADD COLUMN title_user_set INTEGER NOT NULL DEFAULT 0;

-- Treat any existing non-default title as user-edited. Existing "New thread"
-- rows will keep title_user_set=0; the next message sent on them will be
-- titled from that message's prompt, which is a one-time migration effect.
UPDATE threads SET title_user_set = 1 WHERE title != 'New thread';
