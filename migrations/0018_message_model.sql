-- Associate each assistant message with the model that produced it.

ALTER TABLE messages ADD COLUMN model TEXT NOT NULL DEFAULT '';
