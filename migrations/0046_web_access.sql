-- Whether this user's agent runs may spawn the builtin headless browser
-- (`devinorium browser-mcp`). Owner-managed like the MCP server list:
-- browsing from the server is a network-reachable capability.
ALTER TABLE users ADD COLUMN web_access_enabled INTEGER NOT NULL DEFAULT 0;
