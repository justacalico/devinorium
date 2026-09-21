//! Run-lifecycle → push pump.
//!
//! Subscribes to the thread runner's lifecycle feed and pushes terminal
//! statuses and attention requests to the owning user's subscriptions. The
//! feed already scopes events to the right user and fires once per
//! transition; the state kept here is the set of attention kinds already
//! announced per run, reset whenever the flag clears so a request that is
//! answered and re-raised notifies again.

use std::collections::{HashMap, HashSet};

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
    let mut announced: HashMap<String, HashSet<String>> = HashMap::new();
    loop {
        match rx.recv().await {
            Ok(ev) => {
                if let Some(kind) = decide(&mut announced, &ev) {
                    // Sends can take seconds per dead endpoint; run them off
                    // the pump so one slow push service cannot delay or lag
                    // out later events.
                    let state = state.clone();
                    tokio::spawn(send_for_event(state, ev, kind));
                }
            }
            // Lagged receivers miss transitions; pushes are best-effort so a
            // missed one is dropped rather than replayed.
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => break,
        }
        // Bound the map: terminal events remove their entry, but a leaked
        // run would otherwise grow it forever.
        if announced.len() > 1024 {
            announced.clear();
        }
    }
}

/// Decide what (if anything) to push for `ev`, updating `announced` — the
/// per-run set of attention kinds already pushed. Entries are dropped on
/// terminal events and when the attention flag clears, so a request that is
/// answered and re-raised (or a permission flag superseding an ask and then
/// resolving back to it) behaves like a fresh notification exactly once.
fn decide(
    announced: &mut HashMap<String, HashSet<String>>,
    ev: &RunLifecycleEvent,
) -> Option<PushKind> {
    match ev.status {
        RunStatus::Completed => {
            announced.remove(&ev.run_id);
            Some(PushKind::Completed)
        }
        RunStatus::Failed => {
            announced.remove(&ev.run_id);
            Some(PushKind::Failed)
        }
        RunStatus::Stopped => {
            // User-initiated: not worth a push.
            announced.remove(&ev.run_id);
            None
        }
        RunStatus::Running | RunStatus::Idle => {
            let Some(att) = ev.attention.as_deref() else {
                announced.remove(&ev.run_id);
                return None;
            };
            let kind = match att {
                "permission" => PushKind::Permission,
                "ask" => PushKind::Ask,
                _ => {
                    announced.remove(&ev.run_id);
                    return None;
                }
            };
            if !announced
                .entry(ev.run_id.clone())
                .or_default()
                .insert(att.to_string())
            {
                return None;
            }
            Some(kind)
        }
    }
}

/// Look up the thread title and fan the push out to the owner's endpoints.
/// The title is the only DB-dependent part; a thread deleted mid-run has
/// nothing useful left to point at, so the push is skipped.
async fn send_for_event(state: AppState, ev: RunLifecycleEvent, kind: PushKind) {
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

    #[test]
    fn attention_announces_once_per_flag_and_reannounces_after_clear() {
        let mut announced = HashMap::new();
        // permission fires once, then repeats are ignored while pending.
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("permission"))),
            Some(PushKind::Permission)
        );
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("permission"))),
            None
        );
        // permission -> ask is a new kind, so it fires.
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
        // The flag clearing resets the run, so the next request notifies.
        assert_eq!(decide(&mut announced, &ev(RunStatus::Running, None)), None);
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("permission"))),
            Some(PushKind::Permission)
        );
        // Stopped and idle push nothing; completion does.
        assert_eq!(decide(&mut announced, &ev(RunStatus::Stopped, None)), None);
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Completed, None)),
            Some(PushKind::Completed)
        );
        // A run that ends and a fresh attention flag on the next run id
        // is a clean slate.
        let mut e = ev(RunStatus::Running, Some("ask"));
        e.run_id = "r2".into();
        assert_eq!(decide(&mut announced, &e), Some(PushKind::Ask));
    }

    #[test]
    fn attention_flip_does_not_reannounce_a_seen_kind() {
        let mut announced = HashMap::new();
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
        // Permission superseding the pending ask is announced once.
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("permission"))),
            Some(PushKind::Permission)
        );
        // Permission resolved while the ask still pends: the user was
        // already told about this ask, so it stays quiet.
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            None
        );
        // Both answered: the flag clears and the slate resets.
        assert_eq!(decide(&mut announced, &ev(RunStatus::Running, None)), None);
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
    }

    #[test]
    fn terminal_events_clear_dedup_state() {
        let mut announced = HashMap::new();
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Failed, None)),
            Some(PushKind::Failed)
        );
        // Same run id would be unusual after failure, but a fresh attention
        // flag must still announce rather than hitting stale dedup state.
        assert_eq!(
            decide(&mut announced, &ev(RunStatus::Running, Some("ask"))),
            Some(PushKind::Ask)
        );
    }
}
