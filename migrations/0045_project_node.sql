-- Bind a project to a paired satellite node. NULL means the project lives
-- on this server; a value is a federation_nodes.id.
ALTER TABLE projects ADD COLUMN node_id TEXT;
