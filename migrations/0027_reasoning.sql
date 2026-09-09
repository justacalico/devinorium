-- Add the selected reasoning effort to threads.
ALTER TABLE threads ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT '';
