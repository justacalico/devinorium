-- Devinorium schema migration 0036 — Web Push subscriptions.
--
-- One row per browser/device push subscription. The endpoint is unique
-- across users: a browser that resubscribes while signed in as a different
-- user rebinds the row instead of duplicating it. `p256dh`/`auth` are the
-- RFC 8291 encryption keys the subscription hands out; `lang` records the
-- client's locale at subscribe time so pushes arrive localized.

CREATE TABLE push_subscriptions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint   TEXT NOT NULL UNIQUE,
    p256dh     TEXT NOT NULL,
    auth       TEXT NOT NULL,
    lang       TEXT NOT NULL DEFAULT 'en',
    user_agent TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX idx_push_subscriptions_user ON push_subscriptions(user_id);
