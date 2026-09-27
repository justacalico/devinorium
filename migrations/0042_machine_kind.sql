-- Devinorium schema migration 0042 — machine scopes.
--
-- Machines gain a `kind` so an entry describes one protocol scope: `vnc`
-- (screen control, the existing behavior) or `ssh` (remote shell). SSH
-- rows carry a login name and an optional PEM private key; `password`
-- doubles as the SSH login password or the key passphrase. Secrets are
-- never returned by the machine list API.

ALTER TABLE machines ADD COLUMN kind TEXT NOT NULL DEFAULT 'vnc';
ALTER TABLE machines ADD COLUMN ssh_user TEXT NOT NULL DEFAULT '';
ALTER TABLE machines ADD COLUMN ssh_key TEXT NOT NULL DEFAULT '';
-- Host key pinned trust-on-first-use; empty until the first probe sees one.
ALTER TABLE machines ADD COLUMN ssh_fingerprint TEXT NOT NULL DEFAULT '';

-- Guard against typos written outside the API layer.
CREATE TRIGGER machines_kind_check BEFORE INSERT ON machines
    WHEN NEW.kind NOT IN ('vnc', 'ssh')
    BEGIN SELECT RAISE(ABORT, 'invalid machine kind'); END;
CREATE TRIGGER machines_kind_check_update BEFORE UPDATE ON machines
    WHEN NEW.kind NOT IN ('vnc', 'ssh')
    BEGIN SELECT RAISE(ABORT, 'invalid machine kind'); END;
