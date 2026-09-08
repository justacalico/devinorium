//! Usage reporting API.
//!
//! `GET /api/usage` returns the caller's token/cost usage aggregated into
//! `(local day, provider, model)` buckets plus window totals. Data is
//! recorded server-side when a provider reports turn usage, so every client
//! machine sees the same numbers.

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, Router};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::api::map_err_internal;
use crate::auth::session::CurrentUser;
use crate::db::{UsageBucket, UsageTotals};
use crate::AppState;

const DAYS_DEFAULT: i64 = 30;
const DAYS_MAX: i64 = 365;

pub fn router() -> Router<AppState> {
    Router::new().route("/api/usage", get(usage_summary))
}

#[derive(Debug, Deserialize)]
struct UsageQuery {
    /// Inclusive window length in local days.
    days: Option<i64>,
    /// Minutes to add to UTC to reach the viewer's local time
    /// (e.g. -300 for UTC-5). Defaults to UTC.
    tz_offset: Option<i64>,
}

#[derive(Debug, Serialize)]
struct UsageResponse {
    /// Inclusive first day of the window, `YYYY-MM-DD` in the viewer's zone.
    since_day: String,
    /// Inclusive last day of the window, `YYYY-MM-DD` in the viewer's zone.
    until_day: String,
    buckets: Vec<UsageBucket>,
    totals: UsageTotals,
}

async fn usage_summary(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Query(q): Query<UsageQuery>,
) -> Response {
    let days = q.days.unwrap_or(DAYS_DEFAULT).clamp(1, DAYS_MAX);
    let tz_offset = q.tz_offset.unwrap_or(0).clamp(-14 * 60, 14 * 60);
    let tz_modifier = format!("{tz_offset:+} minutes");

    // Day bounds are computed in the viewer's local zone so buckets line up
    // with the days the user actually experienced.
    let row: Option<(String,)> = match sqlx::query_as("SELECT date('now', ?)")
        .bind(&tz_modifier)
        .fetch_optional(state.db.pool())
        .await
    {
        Ok(r) => r,
        Err(e) => return map_err_internal(e).into_response(),
    };
    let Some((until_day,)) = row else {
        return map_err_internal("could not compute local day").into_response();
    };
    let since_day = {
        let row: Option<(String,)> = match sqlx::query_as("SELECT date('now', ?, ?)")
            .bind(&tz_modifier)
            .bind(format!("-{} days", days - 1))
            .fetch_optional(state.db.pool())
            .await
        {
            Ok(r) => r,
            Err(e) => return map_err_internal(e).into_response(),
        };
        match row {
            Some((d,)) => d,
            None => return map_err_internal("could not compute window start").into_response(),
        }
    };

    match state.db.usage_summary(user.id, &since_day, tz_offset).await {
        Ok((buckets, totals)) => Json(UsageResponse {
            since_day,
            until_day,
            buckets,
            totals,
        })
        .into_response(),
        Err(e) => map_err_internal(e).into_response(),
    }
}
