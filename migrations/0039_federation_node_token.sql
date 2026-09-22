-- Devinorium schema migration 0039 — per-node federation tokens.
--
-- The shared DEVINORIUM_FEDERATION_TOKEN used to authenticate every
-- proxied call as the satellite's owner, so each satellite held a skeleton
-- key to every node. The hub now issues each node its own token at
-- registration and sends it on proxied requests instead. NULL on rows
-- created before this migration until the node's next heartbeat.

ALTER TABLE federation_nodes ADD COLUMN token TEXT;
