part of 'package:devinorium_frontend/state/app_state.dart';

/// Turns run lifecycle transitions into local notifications for every
/// thread, not just the open one. Web Push (closed-app delivery) is handled
/// server-side; this covers the foreground/backgrounded app.
mixin NotificationsStore on AppStateBase {
  /// `runId:mark` pairs already notified, so a re-emitted lifecycle event
  /// (attention flags republish on reconnect) cannot fire twice.
  @override
  final Set<String> _notifiedRunKeys = {};

  /// Latest app lifecycle state reported by the widget layer. Null means
  /// "never reported" — treated as foreground so tests and platforms
  /// without lifecycle callbacks stay quiet only for the active thread.
  AppLifecycleState? _appLifecycle;

  @override
  void noteLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;
  }

  /// Whether the app is visibly in front of the user. Notifications are
  /// suppressed for the thread they are already looking at.
  bool get _appInForeground =>
      _appLifecycle == null || _appLifecycle == AppLifecycleState.resumed;

  /// Evaluate a decoded `run_status` event for notification. Snapshots
  /// (`runs`) never reach here — hydrating state must not notify.
  @override
  void _maybeNotifyRunEvent(Map<String, dynamic> j) {
    if (_isDisposed || !_notifications.notificationsEnabled) return;
    final threadId = j['thread_id'];
    final status = j['status'];
    if (threadId is! String || status is! String) return;

    final mark = switch (status) {
      'completed' => 'completed',
      'failed' => 'failed',
      'stopped' => 'stopped',
      'running' => switch (j['attention']) {
        'permission' => 'permission',
        'ask' => 'ask',
        _ => null,
      },
      _ => null,
    };
    if (mark == null) return;

    final runId = j['run_id'];
    final key = runId is String && runId.isNotEmpty
        ? '$runId:$mark'
        : '$threadId:$mark';
    if (!_notifiedRunKeys.add(key)) return;
    // Keys accumulate for the session; bound them so a long-lived app does
    // not grow the set forever.
    if (_notifiedRunKeys.length > 512) {
      _notifiedRunKeys.clear();
      _notifiedRunKeys.add(key);
    }

    // The user is already looking at this thread — its in-app state shows
    // the transition, so a notification would be noise.
    if (threadId == _activeThreadId && _appInForeground) return;

    _notifications.notifyRunEvent(
      threadId: threadId,
      title: _threadTitle(threadId) ?? 'Thread',
      kind: mark,
    );
  }
}
