part of 'package:devinorium_frontend/state/app_state.dart';

/// Context-window state: the active thread's recorded token usage plus the
/// context reset action.
mixin ContextStore on AppStateBase {
  /// The active thread's context usage, or null until it is fetched.
  @override
  ThreadContextUsage? get threadContextUsage => _activeStore?.contextUsage;

  /// Drop the provider session and move the usage watermark to now.
  @override
  Future<void> resetThreadContext() async {
    final store = _activeStore;
    if (store == null) return;
    await store.resetContext();
  }
}
