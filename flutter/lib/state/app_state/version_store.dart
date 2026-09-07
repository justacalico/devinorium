part of 'package:devinorium_frontend/state/app_state.dart';

mixin VersionStore on AppStateBase {
  AppUpdate? _appUpdate;
  VersionChecker? _versionChecker;
  Future<AppUpdate?>? _appUpdateCheck;

  @override
  AppUpdate? get appUpdate => _appUpdate;

  /// Runs an update check and returns the result, or null when the check
  /// fails. Callers can distinguish "no update" from "check failed" without
  /// relying on the cached [appUpdate] value.
  @override
  Future<AppUpdate?> checkForAppUpdate() {
    final existing = _appUpdateCheck;
    if (existing != null) return existing;
    return _appUpdateCheck = _doAppUpdateCheck().whenComplete(
      () => _appUpdateCheck = null,
    );
  }

  Future<AppUpdate?> _doAppUpdateCheck() async {
    try {
      _versionChecker ??= VersionChecker();
      final info = await packageInfo();
      final update = await _versionChecker!.check(info.version);

      final current = _appUpdate;
      if (current == null || current != update) {
        _appUpdate = update;
        _notifyUpdateListeners();
      }
      return update;
    } catch (e) {
      debugLogFailure('versionStore.check', e);
      // The caller gets null so it can show feedback; the cached value keeps
      // whatever the last successful check produced.
      return null;
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
