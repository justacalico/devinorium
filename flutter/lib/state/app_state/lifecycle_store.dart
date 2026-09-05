part of 'package:devinorium_frontend/state/app_state.dart';

mixin LifecycleStore on AppStateBase {
  @override
  Timer? _resumeDebounceTimer;
  @override
  bool _wantsResume = false;
  @override
  bool _isResuming = false;
  @override
  Future<void>? _resumeThreadFuture;

  @override
  void handleAppResumed() {
    if (view != AppView.app) return;
    _wantsResume = true;
    _resumeDebounceTimer?.cancel();
    _resumeDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_onResume());
    });
  }

  Future<void> _onResume() async {
    if (view != AppView.app) return;
    if (_isResuming) return;
    _isResuming = true;
    try {
      if (_healthTimer == null) {
        startHealthChecks();
      }
      await checkConnection();
    } catch (e) {
      debugLogFailure('appState.onResume', e);
    } finally {
      _isResuming = false;
    }
  }

  Future<void> _resumeActiveThread() async {
    if (view != AppView.app) return;
    await refreshRunningThreads();
    final active = _activeStore;
    if (active != null) {
      await active.resume();
    }
  }

  @override
  void _onConnectionRestored() {
    if (!_wantsResume || _resumeThreadFuture != null) return;
    _resumeThreadFuture = _resumeActiveThread().then((_) {
      _wantsResume = false;
    }).catchError((Object e) {
      debugLogFailure('appState.resumeActiveThread', e);
    }).whenComplete(() => _resumeThreadFuture = null);
    unawaited(_resumeThreadFuture!);
  }
}
