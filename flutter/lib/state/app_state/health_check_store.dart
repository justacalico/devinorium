part of 'package:devinorium_frontend/state/app_state.dart';

mixin HealthCheckStore on AppStateBase {
  @override
  ConnectionStatus _connectionStatus = ConnectionStatus.checking;
  @override
  String? _serverVersion;
  @override
  Timer? _healthTimer;
  @override
  Timer? _reconnectTimer;
  @override
  Future<void>? _ongoingCheck;

  @override
  ConnectionStatus get connectionStatus => _connectionStatus;
  @override
  String? get serverVersion => _serverVersion;
  @override
  void startHealthChecks() {
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      checkConnection();
    });
    _reconnectTimer = null;
    checkConnection();
  }
  @override
  void stopHealthChecks() {
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _healthTimer = null;
    _reconnectTimer = null;
  }
  @override
  Future<void> checkConnection() {
    final existing = _ongoingCheck;
    if (existing != null) return existing;
    _ongoingCheck = _doCheck().whenComplete(() => _ongoingCheck = null);
    return _ongoingCheck!;
  }

  Future<void> _doCheck() async {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final api = this.api;
    final profileId = multiServerState.activeServerId;
    var ok = await api.checkHealth();
    var authFailed = false;
    if (ok && multiServerState.activeProfile?.isLocal == true) {
      // /healthz is public, so also prove the bundled token still
      // authenticates; otherwise a stale token looks "connected".
      try {
        await api.me();
      } catch (_) {
        ok = false;
        authFailed = true;
      }
    }
    // A server switch during the check makes the result meaningless for the
    // new profile — drop it; the switch's own load path re-checks anyway.
    if (multiServerState.activeServerId != profileId) return;
    final version = ok ? await api.serverVersion() : null;

    final next = ok ? ConnectionStatus.connected : ConnectionStatus.disconnected;
    var changed = false;
    if (_connectionStatus != next) {
      _connectionStatus = next;
      changed = true;
    }
    if (_serverVersion != version) {
      _serverVersion = version;
      changed = true;
    }
    if (changed && !_isDisposed) {
      notifyListeners();
    }
    if (!ok) {
      // The bundled local server may have died without us noticing, or it
      // can be alive but unauthenticatable (stale token in a respawned
      // process). Only the alive-but-broken case needs a stop() — killing a
      // still-starting spawn would just burn the retry budget.
      if (multiServerState.activeProfile?.isLocal == true) {
        unawaited(() async {
          if (authFailed) await localServerManager.stop();
          await _ensureLocalServer();
        }());
      }
      if (_healthTimer != null) {
        _reconnectTimer = Timer(const Duration(seconds: 2), checkConnection);
      }
    }
    if (_connectionStatus == ConnectionStatus.connected) {
      _onConnectionRestored();
    }
  }
}
