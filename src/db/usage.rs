//! Provider usage data access.
//!
//! Agents report cumulative session counters (ACP `session/prompt` usage and
//! `usage_update` cost), so each recorded event stores the delta against the
//! last snapshot kept in `usage_sessions`. For a brand-new session the first
//! snapshot is counted in full; for a resumed session with no snapshot on
//! file the counters are adopted as a baseline without recording an event,
//! so history from before usage tracking existed is not dumped into a single
//! day.

use serde::Serialize;
use sqlx::{Row, SqliteConnection};

use crate::providers::UsageSnapshot;

/// Input for [`super::Db::record_turn_usage`].
pub struct NewUsageEvent {
    pub user_id: i64,
    pub thread_id: String,
    pub provider_id: String,
    /// Provider-owned session id, used for cumulative diffing. May be absent
    /// when the provider never established a session.
    pub session_id: Option<String>,
    pub model: String,
    /// Cumulative counters reported after the turn.
    pub snapshot: UsageSnapshot,
    /// Whether this run created the session. When false and no prior
    /// snapshot exists, the snapshot is adopted as a baseline instead of
    /// being counted as new usage.
    pub is_new_session: bool,
}

/// One aggregated `(day, provider, model)` cell returned by the usage API.
#[derive(Debug, Clone, Serialize)]
pub struct UsageBucket {
    pub day: String,
    pub provider_id: String,
    pub model: String,
    pub records: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub thought_tokens: i64,
    pub cached_read_tokens: i64,
    pub cached_write_tokens: i64,
    pub total_tokens: i64,
    pub cost_amount: Option<f64>,
    pub cost_currency: Option<String>,
}

/// Sum across all events in the requested window.
#[derive(Debug, Clone, Default, Serialize)]
pub struct UsageTotals {
    pub records: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub thought_tokens: i64,
    pub cached_read_tokens: i64,
    pub cached_write_tokens: i64,
    pub total_tokens: i64,
    /// Cost grouped by currency; empty when no event reported a cost.
    pub costs: Vec<UsageCost>,
}

#[derive(Debug, Clone, Serialize)]
pub struct UsageCost {
    pub currency: String,
    pub amount: f64,
}

fn delta(new: u64, prev: Option<u64>) -> u64 {
    match prev {
        // A counter that moved backwards means the provider restarted its
        // accounting (new session, or per-turn reporting); count it in full.
        Some(p) if new >= p => new - p,
        Some(_) => new,
        None => new,
    }
}

fn delta_f64(new: Option<f64>, prev: Option<f64>) -> Option<f64> {
    match (new, prev) {
        (Some(n), Some(p)) if n >= p => Some(n - p),
        (Some(n), _) => Some(n),
        _ => None,
    }
}

/// The last stored counters for one provider session.
struct PrevSnapshot {
    input_tokens: i64,
    output_tokens: i64,
    thought_tokens: i64,
    cached_read_tokens: i64,
    cached_write_tokens: i64,
    total_tokens: i64,
    cost_amount: Option<f64>,
    cost_currency: Option<String>,
}

impl super::Db {
    /// Record one prompt turn's usage, diffing the cumulative `snapshot`
    /// against the last stored counters for the same provider session.
    ///
    /// Runs in `BEGIN IMMEDIATE` so the write lock is taken before the
    /// baseline read; a deferred transaction would let a concurrent recorder
    /// read the same stale baseline and double-count a turn.
    pub async fn record_turn_usage(&self, event: NewUsageEvent) -> anyhow::Result<()> {
        let mut conn = self.pool().acquire().await?;
        sqlx::query("BEGIN IMMEDIATE").execute(&mut *conn).await?;
        match record_locked(&mut conn, &event).await {
            Ok(()) => {
                sqlx::query("COMMIT").execute(&mut *conn).await?;
                Ok(())
            }
            Err(e) => {
                let _ = sqlx::query("ROLLBACK").execute(&mut *conn).await;
                Err(e)
            }
        }
    }
}

async fn record_locked(conn: &mut SqliteConnection, event: &NewUsageEvent) -> anyhow::Result<()> {
    let snap = &event.snapshot;

    // Rows are keyed by (user, provider, session) because session ids are
    // only unique per provider.
    let prev: Option<PrevSnapshot> = if let Some(sid) = event.session_id.as_deref() {
        sqlx::query(
            "SELECT input_tokens, output_tokens, thought_tokens, cached_read_tokens,
                    cached_write_tokens, total_tokens, cost_amount, cost_currency
             FROM usage_sessions
             WHERE user_id = ? AND provider_id = ? AND session_id = ?",
        )
        .bind(event.user_id)
        .bind(&event.provider_id)
        .bind(sid)
        .fetch_optional(&mut *conn)
        .await?
        .map(|r| PrevSnapshot {
            input_tokens: r.get(0),
            output_tokens: r.get(1),
            thought_tokens: r.get(2),
            cached_read_tokens: r.get(3),
            cached_write_tokens: r.get(4),
            total_tokens: r.get(5),
            cost_amount: r.get(6),
            cost_currency: r.get(7),
        })
    } else {
        None
    };

    // A resumed session we have never seen contributes its history as a
    // baseline only; counting it would attribute old usage to today.
    let baseline_only = prev.is_none() && event.session_id.is_some() && !event.is_new_session;

    // Cost can only be diffed within one currency; when the currency changes
    // (or first appears), keep the reported amount instead of subtracting a
    // foreign-currency baseline.
    let same_currency = prev
        .as_ref()
        .map(|p| p.cost_currency == snap.cost_currency)
        .unwrap_or(false);

    let tokens = if baseline_only {
        UsageSnapshot::default()
    } else {
        UsageSnapshot {
            input_tokens: delta(
                snap.input_tokens,
                prev.as_ref().map(|p| p.input_tokens as u64),
            ),
            output_tokens: delta(
                snap.output_tokens,
                prev.as_ref().map(|p| p.output_tokens as u64),
            ),
            thought_tokens: delta(
                snap.thought_tokens,
                prev.as_ref().map(|p| p.thought_tokens as u64),
            ),
            cached_read_tokens: delta(
                snap.cached_read_tokens,
                prev.as_ref().map(|p| p.cached_read_tokens as u64),
            ),
            cached_write_tokens: delta(
                snap.cached_write_tokens,
                prev.as_ref().map(|p| p.cached_write_tokens as u64),
            ),
            total_tokens: delta(
                snap.total_tokens,
                prev.as_ref().map(|p| p.total_tokens as u64),
            ),
            cost_amount: if prev.is_none() || same_currency {
                delta_f64(snap.cost_amount, prev.as_ref().and_then(|p| p.cost_amount))
            } else {
                snap.cost_amount
            },
            cost_currency: if snap.cost_amount.is_some() {
                snap.cost_currency.clone()
            } else {
                None
            },
        }
    };

    if let Some(sid) = event.session_id.as_deref() {
        sqlx::query(
            "INSERT INTO usage_sessions
                (user_id, provider_id, session_id, input_tokens, output_tokens, thought_tokens,
                 cached_read_tokens, cached_write_tokens, total_tokens, cost_amount, cost_currency, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
             ON CONFLICT (user_id, provider_id, session_id) DO UPDATE SET
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                thought_tokens = excluded.thought_tokens,
                cached_read_tokens = excluded.cached_read_tokens,
                cached_write_tokens = excluded.cached_write_tokens,
                total_tokens = excluded.total_tokens,
                cost_amount = excluded.cost_amount,
                cost_currency = excluded.cost_currency,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')",
        )
        .bind(event.user_id)
        .bind(&event.provider_id)
        .bind(sid)
        .bind(snap.input_tokens as i64)
        .bind(snap.output_tokens as i64)
        .bind(snap.thought_tokens as i64)
        .bind(snap.cached_read_tokens as i64)
        .bind(snap.cached_write_tokens as i64)
        .bind(snap.total_tokens as i64)
        .bind(snap.cost_amount)
        .bind(&snap.cost_currency)
        .execute(&mut *conn)
        .await?;
    }

    if !baseline_only {
        sqlx::query(
            "INSERT INTO usage_events
                (user_id, thread_id, provider_id, session_id, model,
                 input_tokens, output_tokens, thought_tokens,
                 cached_read_tokens, cached_write_tokens, total_tokens,
                 cost_amount, cost_currency)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(event.user_id)
        .bind(&event.thread_id)
        .bind(&event.provider_id)
        .bind(&event.session_id)
        .bind(&event.model)
        .bind(tokens.input_tokens as i64)
        .bind(tokens.output_tokens as i64)
        .bind(tokens.thought_tokens as i64)
        .bind(tokens.cached_read_tokens as i64)
        .bind(tokens.cached_write_tokens as i64)
        .bind(tokens.total_tokens as i64)
        .bind(tokens.cost_amount)
        .bind(&tokens.cost_currency)
        .execute(&mut *conn)
        .await?;
    }

    Ok(())
}

impl super::Db {
    /// Aggregate the user's usage into `(local day, provider, model)` buckets
    /// plus window totals. `tz_offset_minutes` is the offset to add to UTC to
    /// get the viewer's local time (e.g. -300 for UTC-5); `since_day` is an
    /// inclusive `YYYY-MM-DD` lower bound in that local zone.
    pub async fn usage_summary(
        &self,
        user_id: i64,
        since_day: &str,
        tz_offset_minutes: i64,
    ) -> anyhow::Result<(Vec<UsageBucket>, UsageTotals)> {
        let tz_modifier = format!("{tz_offset_minutes:+} minutes");

        let rows = sqlx::query(
            // cost_currency joins the grouping so a bucket never mixes
            // amounts from different currencies into one sum.
            "SELECT date(created_at, ?) AS day, provider_id, model, cost_currency,
                    COUNT(*) AS records,
                    SUM(input_tokens) AS input_tokens,
                    SUM(output_tokens) AS output_tokens,
                    SUM(thought_tokens) AS thought_tokens,
                    SUM(cached_read_tokens) AS cached_read_tokens,
                    SUM(cached_write_tokens) AS cached_write_tokens,
                    SUM(total_tokens) AS total_tokens,
                    SUM(cost_amount) AS cost_amount
             FROM usage_events
             WHERE user_id = ? AND date(created_at, ?) >= ?
             GROUP BY day, provider_id, model, cost_currency
             ORDER BY day, provider_id, model, cost_currency",
        )
        .bind(&tz_modifier)
        .bind(user_id)
        .bind(&tz_modifier)
        .bind(since_day)
        .fetch_all(self.pool())
        .await?;

        let mut buckets = Vec::with_capacity(rows.len());
        let mut totals = UsageTotals::default();
        for r in rows {
            let b = UsageBucket {
                day: r.get("day"),
                provider_id: r.get("provider_id"),
                model: r.get("model"),
                records: r.get("records"),
                input_tokens: r.get("input_tokens"),
                output_tokens: r.get("output_tokens"),
                thought_tokens: r.get("thought_tokens"),
                cached_read_tokens: r.get("cached_read_tokens"),
                cached_write_tokens: r.get("cached_write_tokens"),
                total_tokens: r.get("total_tokens"),
                cost_amount: r.get("cost_amount"),
                cost_currency: r.get("cost_currency"),
            };
            totals.records += b.records;
            totals.input_tokens += b.input_tokens;
            totals.output_tokens += b.output_tokens;
            totals.thought_tokens += b.thought_tokens;
            totals.cached_read_tokens += b.cached_read_tokens;
            totals.cached_write_tokens += b.cached_write_tokens;
            totals.total_tokens += b.total_tokens;
            if let Some(amount) = b.cost_amount {
                let currency = b.cost_currency.clone().unwrap_or_default();
                match totals.costs.iter_mut().find(|c| c.currency == currency) {
                    Some(c) => c.amount += amount,
                    None => totals.costs.push(UsageCost { currency, amount }),
                }
            }
            buckets.push(b);
        }

        Ok((buckets, totals))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::NewUser;

    async fn test_db() -> (crate::db::Db, i64) {
        let db = crate::db::Db::connect("sqlite::memory:").await.unwrap();
        let user = db
            .create_user(NewUser {
                username: "u".into(),
                password_hash: "x".into(),
                is_owner: false,
            })
            .await
            .unwrap();
        (db, user.id)
    }

    fn event(user_id: i64, session: &str, is_new: bool, snap: UsageSnapshot) -> NewUsageEvent {
        NewUsageEvent {
            user_id,
            thread_id: "t1".into(),
            provider_id: "devin-cli".into(),
            session_id: Some(session.into()),
            model: "glm-5-2".into(),
            snapshot: snap,
            is_new_session: is_new,
        }
    }

    fn snap(input: u64, output: u64) -> UsageSnapshot {
        UsageSnapshot {
            input_tokens: input,
            output_tokens: output,
            total_tokens: input + output,
            ..UsageSnapshot::default()
        }
    }

    #[tokio::test]
    async fn first_turn_of_new_session_counts_in_full() {
        let (db, uid) = test_db().await;
        db.record_turn_usage(event(uid, "s1", true, snap(100, 50)))
            .await
            .unwrap();
        let (buckets, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert_eq!(buckets.len(), 1);
        assert_eq!(buckets[0].input_tokens, 100);
        assert_eq!(buckets[0].output_tokens, 50);
        assert_eq!(totals.total_tokens, 150);
        assert_eq!(totals.records, 1);
    }

    #[tokio::test]
    async fn second_turn_records_only_the_delta() {
        let (db, uid) = test_db().await;
        db.record_turn_usage(event(uid, "s1", true, snap(100, 50)))
            .await
            .unwrap();
        db.record_turn_usage(event(uid, "s1", false, snap(300, 120)))
            .await
            .unwrap();
        let (_, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert_eq!(totals.input_tokens, 300);
        assert_eq!(totals.output_tokens, 120);
        assert_eq!(totals.records, 2);
    }

    #[tokio::test]
    async fn resumed_unknown_session_becomes_baseline_without_event() {
        let (db, uid) = test_db().await;
        // A session that existed before usage tracking reports its whole
        // history; adopt it as the baseline so it is not counted as new.
        db.record_turn_usage(event(uid, "s1", false, snap(10_000, 5_000)))
            .await
            .unwrap();
        let (buckets, _) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert!(buckets.is_empty());
        // The following turn diffs against that baseline.
        db.record_turn_usage(event(uid, "s1", false, snap(10_100, 5_050)))
            .await
            .unwrap();
        let (_, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert_eq!(totals.total_tokens, 150);
    }

    #[tokio::test]
    async fn counter_reset_counts_the_new_value() {
        let (db, uid) = test_db().await;
        db.record_turn_usage(event(uid, "s1", true, snap(500, 200)))
            .await
            .unwrap();
        // Provider restarted its accounting; the lower value is per-turn.
        db.record_turn_usage(event(uid, "s1", false, snap(80, 40)))
            .await
            .unwrap();
        let (_, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert_eq!(totals.input_tokens, 580);
    }

    #[tokio::test]
    async fn cost_is_diffed_and_grouped_by_currency() {
        let (db, uid) = test_db().await;
        let mut s = snap(10, 5);
        s.cost_amount = Some(1.50);
        s.cost_currency = Some("USD".into());
        db.record_turn_usage(event(uid, "s1", true, s))
            .await
            .unwrap();
        let mut s2 = snap(20, 10);
        s2.cost_amount = Some(2.00);
        s2.cost_currency = Some("USD".into());
        db.record_turn_usage(event(uid, "s1", false, s2))
            .await
            .unwrap();
        let (_, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        assert_eq!(totals.costs.len(), 1);
        assert_eq!(totals.costs[0].currency, "USD");
        assert!((totals.costs[0].amount - 2.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn same_session_id_for_different_users_tracks_independently() {
        let (db, uid) = test_db().await;
        let other = db
            .create_user(NewUser {
                username: "other".into(),
                password_hash: "x".into(),
                is_owner: false,
            })
            .await
            .unwrap();
        db.record_turn_usage(event(uid, "s1", true, snap(100, 50)))
            .await
            .unwrap();
        // A different user's first turn on the same provider session id must
        // not diff against the first user's baseline.
        db.record_turn_usage(event(other.id, "s1", true, snap(40, 20)))
            .await
            .unwrap();
        let (_, totals_a) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        let (_, totals_b) = db.usage_summary(other.id, "1970-01-01", 0).await.unwrap();
        assert_eq!(totals_a.total_tokens, 150);
        assert_eq!(totals_b.total_tokens, 60);
    }

    #[tokio::test]
    async fn currency_change_keeps_the_new_amount_whole() {
        let (db, uid) = test_db().await;
        let mut s = snap(10, 5);
        s.cost_amount = Some(100.0);
        s.cost_currency = Some("CREDITS".into());
        db.record_turn_usage(event(uid, "s1", true, s))
            .await
            .unwrap();
        // Provider switched to reporting dollars; 5 USD is not 5 - 100.
        let mut s2 = snap(20, 10);
        s2.cost_amount = Some(5.0);
        s2.cost_currency = Some("USD".into());
        db.record_turn_usage(event(uid, "s1", false, s2))
            .await
            .unwrap();
        let (_, totals) = db.usage_summary(uid, "1970-01-01", 0).await.unwrap();
        let usd = totals.costs.iter().find(|c| c.currency == "USD").unwrap();
        assert!((usd.amount - 5.0).abs() < 1e-9);
        let creds = totals
            .costs
            .iter()
            .find(|c| c.currency == "CREDITS")
            .unwrap();
        assert!((creds.amount - 100.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn summary_is_scoped_per_user() {
        let (db, uid) = test_db().await;
        let other = db
            .create_user(NewUser {
                username: "other".into(),
                password_hash: "x".into(),
                is_owner: false,
            })
            .await
            .unwrap();
        db.record_turn_usage(event(uid, "s1", true, snap(100, 50)))
            .await
            .unwrap();
        let (buckets, _) = db.usage_summary(other.id, "1970-01-01", 0).await.unwrap();
        assert!(buckets.is_empty());
    }

    #[tokio::test]
    async fn since_day_filters_older_events() {
        let (db, uid) = test_db().await;
        db.record_turn_usage(event(uid, "s1", true, snap(100, 50)))
            .await
            .unwrap();
        // Events recorded today are excluded by a future since_day.
        let (buckets, _) = db.usage_summary(uid, "2999-01-01", 0).await.unwrap();
        assert!(buckets.is_empty());
    }
}
