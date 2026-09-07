part of 'package:devinorium_frontend/state/app_state.dart';

mixin VersionStore on AppStateBase {
  AppUpdate? _appUpdate;
  VersionChecker? _versionChecker;
  Future<void>? _appUpdateCheck;

  @override
  AppUpdate? get appUpdate => _appUpdate;

  @override
  Future<void> checkForAppUpdate() {
    final existing = _appUpdateCheck;
    if (existing != null) return existing;
    _appUpdateCheck = _doAppUpdateCheck().whenComplete(
      () => _appUpdateCheck = null,
    );
    return _appUpdateCheck!;
  }

  Future<void> _doAppUpdateCheck() async {
    try {
      _versionChecker ??= VersionChecker();
      final info = await packageInfo();
      final update = await _versionChecker!.check(info.version);

      final current = _appUpdate;
      if (current != null && current == update) return;

      _appUpdate = update;
      _notifyUpdateListeners();
    } catch (e) {
      debugLogFailure('versionStore.check', e);
      // A failed version check is not worth surfacing as an error. The
      // About page simply stays in its current state.
    }
  }

  void _notifyUpdateListeners() {
    try {
      notifyListeners();
    } catch (e) {
      debugLogFailure('versionStore.notifyListeners', e);
    }
  }
}

/// A [VersionChecker] that never touches the network, used as the default for
/// [AppState.test] so tests that open the About page do not make real requests.
class _NoNetworkVersionChecker extends VersionChecker {
  _NoNetworkVersionChecker() : super(client: null);

  @override
  Future<AppUpdate> check(String currentVersion) async => AppUpdate(
        currentVersion: currentVersion,
        releaseUrl: VersionChecker.releasesUrl,
      );
}
