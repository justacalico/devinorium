//! Persistent message-level event stream.
//!
//! Clients connect to this SSE endpoint with an optional `?since_seq=N` query
//! parameter. The server replays any persisted messages with `seq > N`, or,
//! if the gap is too large, sends a fresh windowed snapshot instead. After the
//! replay the stream stays open and polls for new messages.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use futures::stream::{self, BoxStream, StreamExt};
use serde::Deserialize;
use tokio::sync::Mutex;
use tokio_stream::wrappers::IntervalStream;

use crate::api::threads::send::sanitize_sse_data;
use crate::auth::session::CurrentUser;
use crate::db::messages::TURN_LIMIT_DEFAULT;
use crate::AppState;

use super::MessageOut;

const EVENT_GAP_THRESHOLD: i64 = 1_000;
const POLL_INTERVAL_MS: u64 = 500;

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct StreamQuery {
    pub since_seq: Option<i64>,
    pub turn_limit: Option<i64>,
    pub live: Option<bool>,
}

impl Default for StreamQuery {
    fn default() -> Self {
        Self {
            since_seq: Some(0),
            turn_limit: Some(TURN_LIMIT_DEFAULT),
            live: Some(true),
        }
    }
}

pub(super) async fn message_stream(
    State(state): State<AppState>,
    CurrentUser(user): CurrentUser,
    Path(thread_id): Path<String>,
    Query(query): Query<StreamQuery>,
) -> Response {
    match state.db.get_thread(&thread_id, user.id).await {
        Ok(Some(_)) => {}
        _ => {
            return (
                axum::http::StatusCode::NOT_FOUND,
                axum::Json(crate::api::ApiError::new("not found")),
            )
                .into_response();
        }
    }

    let since_seq = query.since_seq.unwrap_or(0).max(0);
    let turn_limit = query.turn_limit.unwrap_or(TURN_LIMIT_DEFAULT).clamp(1, 200);
    let live = query.live.unwrap_or(true);

    let (initial, watermark) =
        match build_initial_events(&state, &thread_id, since_seq, turn_limit).await {
            Ok(v) => v,
            Err(e) => return crate::api::map_err_internal(e).into_response(),
        };

    let combined: BoxStream<'static, Result<Event, Infallible>> = if live {
        let live = live_message_stream(state.clone(), thread_id.clone(), watermark);
        stream::iter(initial).chain(live).boxed()
    } else {
        stream::iter(initial).boxed()
    };

    Sse::new(Box::pin(combined))
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response()
}

async fn build_initial_events(
    state: &AppState,
    thread_id: &str,
    since_seq: i64,
    turn_limit: i64,
) -> anyhow::Result<(Vec<Result<Event, Infallible>>, i64)> {
    let max_seq = state.db.max_seq(thread_id).await?;

    if max_seq - since_seq > EVENT_GAP_THRESHOLD {
        let (rows, _total, before_cursor, has_more) = state
            .db
            .list_messages_turn_windowed(thread_id, None, turn_limit)
            .await?;
        let messages: Vec<MessageOut> = rows.into_iter().map(MessageOut::from).collect();
        let snapshot = serde_json::json!({
            "event": "snapshot",
            "messages": messages,
            "watermark": max_seq,
            "before_cursor": before_cursor.map(|c| c.encode()),
            "has_more": has_more,
        });
        return Ok((
            vec![Ok(Event::default()
                .event("snapshot")
                .data(sanitize_sse_data(&snapshot.to_string())))],
            max_seq,
        ));
    }

    let rows = state
        .db
        .list_messages_since(thread_id, since_seq, EVENT_GAP_THRESHOLD)
        .await?;
    let mut events = Vec::new();
    for row in rows {
        let msg = MessageOut::from(row);
        events.push(Ok(Event::default()
            .event("message-sent")
            .id(msg.seq.to_string())
            .data(sanitize_sse_data(&serde_json::to_string(&msg)?))));
    }
    Ok((events, max_seq))
}

fn live_message_stream(
    state: AppState,
    thread_id: String,
    start_seq: i64,
) -> BoxStream<'static, Result<Event, Infallible>> {
    let last_seq = Arc::new(Mutex::new(start_seq));
    let interval = tokio::time::interval(Duration::from_millis(POLL_INTERVAL_MS));
    IntervalStream::new(interval)
        .then(move |_| {
            let state = state.clone();
            let thread_id = thread_id.clone();
            let last_seq = last_seq.clone();
            async move {
                let mut batch = Vec::new();
                let since = *last_seq.lock().await;
                match state
                    .db
                    .list_messages_since(&thread_id, since, EVENT_GAP_THRESHOLD)
                    .await
                {
                    Ok(rows) => {
                        let mut max = since;
                        for row in rows {
                            max = max.max(row.seq);
                            let msg = MessageOut::from(row);
                            batch.push(Ok(Event::default()
                                .event("message-sent")
                                .id(msg.seq.to_string())
                                .data(sanitize_sse_data(
                                    &serde_json::to_string(&msg).unwrap_or_default(),
                                ))));
                        }
                        *last_seq.lock().await = max;
                    }
                    Err(e) => {
                        eprintln!("live_message_stream db error: {e}");
                    }
                }
                stream::iter(batch)
            }
        })
        .flatten()
        .boxed()
}
