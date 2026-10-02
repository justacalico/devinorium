-- Devinorium schema migration 0044
-- Owner-managed MCP server list, stored as a JSON array on the user row.

ALTER TABLE users ADD COLUMN mcp_servers TEXT NOT NULL DEFAULT '[]';
