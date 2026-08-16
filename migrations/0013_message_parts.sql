-- Add ordered message parts and backfill from legacy content/thinking columns.

ALTER TABLE messages ADD COLUMN parts TEXT;

UPDATE messages
SET parts = json_array(json_object('type','text','content',content))
WHERE content IS NOT NULL AND (thinking IS NULL OR thinking = '');

UPDATE messages
SET parts = json_array(
    json_object('type','text','content',content),
    json_object('type','thinking','content',thinking)
)
WHERE content IS NOT NULL AND thinking IS NOT NULL AND thinking <> '';

UPDATE messages
SET parts = '[]'
WHERE content IS NULL;
