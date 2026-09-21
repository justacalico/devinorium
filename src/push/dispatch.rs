//! Run-lifecycle → push pump.
//!
//! Subscribes to the thread runner's lifecycle feed and pushes terminal
//! statuses and attention requests to the owning user's subscriptions. The
//! feed already scopes events to the right user and fires once per
//! transition, so the only state kept here is the last-seen attention flag
//! per run — needed because `publish_attention` can re-fire `running` events
//! for a request the user already saw.

use std::collections::HashMap;

use tokio::sync::broadcast::error::RecvError;

use crate::thread_runner::{RunLifecycleEvent, RunStatus};
use crate::AppState;

use super::PushKind;

/// Spawn the dispatcher as a background task. No-op when push is disabled
/// (tests, or a PushService that was never initialized).
pub fn spawn_dispatch(state: &AppState) {
    if !state.push.enabled() {
        return;
    }
    let rx = state.thread_runner.subscribe_lifecycle();
    let state = state.clone();
    tokio::spawn(async move {
        pump(state, rx).await;
    });
}

async fn pump(state: AppState, mut rx: tokio::sync::broadcast::Receiver<RunLifecycleEvent>) {
    let mut last_attention: HashMap<String, Option<String>> = HashMap::new();
    loop {
        match rx.recv().await {
            Ok(ev) => handle_event(&state, &mut last_attention, ev).await,
            // Lagged receivers miss transitions; pushes are best-effort so a
            // missed one is dropped rather than replayed.
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => break,
        }
        // Bound the map: terminal events remove their entry, but a leaked
        // run would otherwise grow it forever.
        if last_attention.len() > 1024 {
            last_attention.clear();
        }
    }
}

/// Decide what (if anything) to push for `ev` and send it.
async fn handle_event(
    state: &AppState,
    last_attention: &mut HashMap<String, Option<String>>,
    ev: RunLifecycleEvent,
) {
    let kind = match ev.status {
        RunStatus::Completed => {
            last_attention.remove(&ev.run_id);
            PushKind::Completed
        }
        RunStatus::Failed => {
            last_attention.remove(&ev.run_id);
            PushKind::Failed
        }
        RunStatus::Stopped => {
            // User-initiated: not worth a push.
            last_attention.remove(&ev.run_id);
            return;
        }
        RunStatus::Running | RunStatus::Idle => {
            let prev = last_attention.insert(ev.run_id.clone(), ev.attention.clone());
            let Some(att) = ev.attention.as_deref() else {
                return;
            };
            // Re-emitted running events for the same pending request do not
            // re-notify; permission→ask transitions do.
            if prev.flatten().as_deref() == Some(att) {
                return;
            }
            match att {
                "permission" => PushKind::Permission,
                "ask" => PushKind::Ask,
                _ => return,
            }
        }
    };

    // The title is the only DB-dependent part; a thread deleted mid-run has
    // nothing useful left to point at, so the push is skipped.
    let thread = match state.db.get_thread(&ev.thread_id, ev.user_id).await {
        Ok(Some(t)) => t,
        Ok(None) => return,
        Err(e) => {
            tracing::warn!(error = %e, thread_id = %ev.thread_id, "push: thread lookup failed");
            return;
        }
    };
    state
        .push
        .send_to_user(ev.user_id, kind, &thread.id, &thread.title)
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(status: RunStatus, attention: Option<&str>) -> RunLifecycleEvent {
        RunLifecycleEvent {
            thread_id: "t".into(),
            run_id: "r".into(),
            user_id: 1,
            status,
            error: None,
            attention: attention.map(str::to_string),
            updated_at: "now".into(),
        }
    }

    /// The attention dedup is the one piece of dispatch logic with real
    /// state; exercise it through a stand-in that mirrors handle_event's
    /// decision table without needing an AppState.
    #[test]
    fn attention_transitions_dedup_per_run() {
        fn decide(
            last: &mut HashMap<String, Option<String>>,
            ev: &RunLifecycleEvent,
        ) -> Option<PushKind> {
            match ev.status {
                RunStatus::Completed => {
                    last.remove(&ev.run_id);
                    Some(PushKind::Completed)
                }
                RunStatus::Failed => {
                    last.remove(&ev.run_id);
                    Some(PushKind::Failed)
                }
                RunStatus::Stopped => {
                    last.remove(&ev.run_id);
                    None
                }
                _ => {
                    let prev = last.insert(ev.run_id.clone(), ev.attention.clone());
                    let prev = prev.flatten();
                    match ev.attention.as_deref() {
                        Some("permission") if prev.as_deref() != Some("permission") => {
                            Some(PushKind::Permission)
                        }
                        Some("ask") if prev.as_deref() != Some("ask") => Some(PushKind::Ask),
                        _ => None,
                    }
                }
            }
        }

        let mut last = HashMap::new();
        // permission fires once, then repeats are ignored until cleared.
        assert_eq!(
            decide(&mut last, &ev(RunStatus::Running, Some("permission"))),
            Some(PushKind::Permission)
        );
        assert_eq!(
            decide(&mut last, &ev(RunStatus::Running, Some("permission"))),
            None
        );
        // permission -> ask is a new kind, so it fires.
        assert_eq!(
            decide(&mut last, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
        // Clearing then re-requesting permission fires again.
        assert_eq!(decide(&mut last, &ev(RunStatus::Running, None)), None);
        assert_eq!(
            decide(&mut last, &ev(RunStatus::Running, Some("permission"))),
            Some(PushKind::Permission)
        );
        // Stopped and idle push nothing; completion does.
        assert_eq!(decide(&mut last, &ev(RunStatus::Stopped, None)), None);
        assert_eq!(
            decide(&mut last, &ev(RunStatus::Completed, None)),
            Some(PushKind::Completed)
        );
        // A run that ends and a fresh attention flag on the next run id
        // is a clean slate.
        let mut e = ev(RunStatus::Running, Some("ask"));
        e.run_id = "r2".into();
        assert_eq!(decide(&mut last, &e), Some(PushKind::Ask));
    }
}
