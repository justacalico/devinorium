part of 'package:devinorium_frontend/state/app_state.dart';

/// Follows the global `/api/threads/runs/events` stream so every sidebar tile
/// tracks its own run — not just the thread currently open. This is the same
/// shape t3code uses: one lifecycle feed, per-thread state keyed by id.
mixin RunEventsStore on AppStateBase {
  StreamSubscription<SseEvent>? _runEventsSub;
  bool _runEventsUnsupported = false;

  /// Latest status reported by the lifecycle stream, keyed by thread id.
  @override
  final Map<String, String> _threadRunStatuses = {};

  /// 'permission' or 'ask' while a run waits on input, keyed by thread id.
  @override
  final Map<String, String> _threadRunAttention = {};

  /// Whether the lifecycle stream is the live source of truth for running
  /// threads. While connected, the legacy poll leaves `_runningThreadIds`
  /// alone so a stale poll response cannot resurrect a finished run.
  @override
  bool get _runEventsConnected =>
      _runEventsSub != null && !_runEventsUnsupported;

  @override
  String? threadRunStatus(String threadId) => _threadRunStatuses[threadId];

  @override
  String? threadRunAttention(String threadId) => _threadRunAttention[threadId];

  /// Drop the cached lifecycle state for a thread that no longer exists.
  @override
  void _dropRunEventState(String threadId) {
    _runningThreadIds.remove(threadId);
    _threadRunStatuses.remove(threadId);
    _threadRunAttention.remove(threadId);
  }

  /// Open the lifecycle stream unless it is already running, unsupported by
  /// the server, or nobody is logged in. Safe to call from any auth or
  /// reconnect path; extra calls are no-ops.
  @override
  void _ensureRunEvents() {
    if (_isDisposed ||
        _runEventsUnsupported ||
        _runEventsSub != null ||
        _user == null) {
      return;
    }
    try {
      // Capture the subscription so a late error/done from a cancelled
      // stream cannot clear a newer subscription's reference.
      late StreamSubscription<SseEvent> sub;
      sub = api.watchRunEvents().listen(
        _onRunEvent,
        onError: (e) => _onRunEventsClosed(sub, e),
        onDone: () => _onRunEventsClosed(sub, null),
      );
      _runEventsSub = sub;
    } catch (e) {
      // The stream could not even be opened (offline, misconfigured
      // client); the next reconnect attempt will try again.
      debugLogFailure('runEvents.open', e);
    }
  }

  /// Force the lifecycle stream to reconnect. Used when connectivity flips
  /// back to connected, because a dead socket does not always report an
  /// error — the server keep-alives are invisible to the parser. Cached
  /// state is kept until the fresh snapshot replaces it.
  @override
  void _restartRunEvents() {
    _runEventsSub?.cancel();
    _runEventsSub = null;
    _runEventsUnsupported = false;
    _ensureRunEvents();
  }

  @override
  void _stopRunEvents() {
    _runEventsSub?.cancel();
    _runEventsSub = null;
    _runEventsUnsupported = false;
    _threadRunStatuses.clear();
    _threadRunAttention.clear();
    _runningThreadIds.clear();
  }

  void _onRunEventsClosed(StreamSubscription<SseEvent> sub, Object? error) {
    if (identical(_runEventsSub, sub)) {
      _runEventsSub = null;
    }
    // An old server has no such endpoint; polling stays the fallback there
    // and reopening would just hammer it with 404s.
    if (error is ApiException &&
        (error.statusCode == 404 ||
            error.statusCode == 405 ||
            error.statusCode == 501)) {
      _runEventsUnsupported = true;
      return;
    }
    if (error != null) {
      debugLogFailure('runEvents.stream', error);
    }
    // No ad-hoc retry: the health-check loop calls _onConnectionRestored
    // on every successful check, which reopens the stream.
  }

  void _onRunEvent(SseEvent ev) {
    if (_isDisposed) return;
    if (ev.event == 'runs') {
      _applyRunsSnapshot(ev.data);
    } else if (ev.event == 'run_status') {
      _applyRunStatus(ev.data);
    }
  }

  /// The `runs` snapshot is authoritative for everything still tracked by
  /// the runner: live runs, plus recently finished records kept around for
  /// reconnecting clients. Entries for threads absent from the snapshot are
  /// dropped so the tile falls back to the persisted last message role.
  void _applyRunsSnapshot(String data) {
    final j = tryDecodeJson(data);
    if (j == null) return;
    final ids = j['running_ids'];
    final live = <String>{
      if (ids is List) ...ids.whereType<String>(),
    };
    _runningThreadIds
      ..clear()
      ..addAll(live);
    _threadRunAttention.removeWhere((id, _) => !live.contains(id));

    final runs = j['runs'];
    if (runs is! List) {
      notifyListeners();
      return;
    }
    final seen = <String>{};
    for (final r in runs) {
      if (r is! Map<String, dynamic>) continue;
      final tid = r['thread_id'];
      if (tid is! String) continue;
      seen.add(tid);
      final status = r['status'];
      _threadRunStatuses[tid] = status is String ? status : 'running';
      final attention = r['attention'];
      if (attention is String) {
        _threadRunAttention[tid] = attention;
      } else {
        _threadRunAttention.remove(tid);
      }
    }
    // Anything the runner no longer tracks (run record expired, or a run
    // that started and finished during a gap) loses its cached status so
    // the persisted last message role takes over.
    var dropped = false;
    _threadRunStatuses.removeWhere((id, _) {
      if (seen.contains(id)) return false;
      dropped = true;
      return true;
    });
    if (dropped) {
      // The fallback reads lastMessageRole off the thread list, which may
      // be stale after a disconnect; refetch so the tile settles correctly.
      unawaited(refreshThreadsAndGroups());
    }
    notifyListeners();
  }

  void _applyRunStatus(String data) {
    final j = tryDecodeJson(data);
    if (j == null) return;
    final tid = j['thread_id'];
    final status = j['status'];
    if (tid is! String || status is! String) return;
    if (status == 'running') {
      _runningThreadIds.add(tid);
      _threadRunStatuses[tid] = 'running';
      final attention = j['attention'];
      if (attention is String) {
        _threadRunAttention[tid] = attention;
      } else {
        _threadRunAttention.remove(tid);
      }
    } else {
      // Terminal statuses stay cached so the tile keeps showing
      // done/failed/stopped after the run record is gone server-side.
      _runningThreadIds.remove(tid);
      _threadRunAttention.remove(tid);
      _threadRunStatuses[tid] = status;
    }
    notifyListeners();
  }

  @visibleForTesting
  void handleRunEventForTest(SseEvent ev) => _onRunEvent(ev);
}
