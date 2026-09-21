//! Push subscription persistence.
//!
//! Web Push subscriptions live in `push_subscriptions`, keyed by endpoint so
//! a browser resubscribing (key rotation, new login) updates in place rather
//! than stacking rows. Rows belong to a user; a subscription created while
//! signed in as someone else is rebound on the next upsert.

use serde::{Deserialize, Serialize};

/// A row from the `push_subscriptions` table.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct PushSubscriptionRow {
    pub id: i64,
    pub user_id: i64,
    pub endpoint: String,
    pub p256dh: String,
    pub auth: String,
    pub lang: String,
    pub user_agent: String,
    pub created_at: String,
    pub updated_at: String,
}

impl super::Db {
    /// Insert or refresh a subscription for `user_id`. The endpoint is
    /// globally unique — a resubscribe rebinds it to the caller and updates
    /// the keys in case the browser rotated them.
    pub async fn upsert_push_subscription(
        &self,
        user_id: i64,
        endpoint: &str,
        p256dh: &str,
        auth: &str,
        lang: &str,
        user_agent: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, lang, user_agent)
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(endpoint) DO UPDATE SET
               user_id = excluded.user_id,
               p256dh = excluded.p256dh,
               auth = excluded.auth,
               lang = excluded.lang,
               user_agent = excluded.user_agent,
               updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')",
        )
        .bind(user_id)
        .bind(endpoint)
        .bind(p256dh)
        .bind(auth)
        .bind(lang)
        .bind(user_agent)
        .execute(self.pool())
        .await?;
        Ok(())
    }

    /// Remove a subscription by endpoint. Only the owning user may delete it.
    pub async fn delete_push_subscription(
        &self,
        user_id: i64,
        endpoint: &str,
    ) -> anyhow::Result<bool> {
        let res = sqlx::query("DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?")
            .bind(endpoint)
            .bind(user_id)
            .execute(self.pool())
            .await?;
        Ok(res.rows_affected() > 0)
    }

    /// Drop a subscription whose endpoint the push service reported as gone
    /// (404/410). Ownership is not checked — a dead endpoint is dead for
    /// everyone.
    pub async fn prune_push_endpoint(&self, endpoint: &str) -> anyhow::Result<()> {
        sqlx::query("DELETE FROM push_subscriptions WHERE endpoint = ?")
            .bind(endpoint)
            .execute(self.pool())
            .await?;
        Ok(())
    }

    /// All subscriptions belonging to a user.
    pub async fn push_subscriptions_for_user(
        &self,
        user_id: i64,
    ) -> anyhow::Result<Vec<PushSubscriptionRow>> {
        let rows = sqlx::query_as::<_, PushSubscriptionRow>(
            "SELECT id, user_id, endpoint, p256dh, auth, lang, user_agent, created_at, updated_at
             FROM push_subscriptions WHERE user_id = ? ORDER BY created_at",
        )
        .bind(user_id)
        .fetch_all(self.pool())
        .await?;
        Ok(rows)
    }
}
