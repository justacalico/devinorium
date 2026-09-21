-- Per-thread output token cap and the context-reset watermark.
--
-- `max_output_tokens` overrides the model's advertised output limit when the
-- provider accepts one (stored for display otherwise).
--
-- `context_cleared_seq` records the seq watermark of the last "reset
-- context" action: the provider session is dropped at the same time, so the
-- context estimate only counts messages written after the watermark.
ALTER TABLE threads ADD COLUMN max_output_tokens INTEGER;
ALTER TABLE threads ADD COLUMN context_cleared_seq INTEGER NOT NULL DEFAULT 0;
