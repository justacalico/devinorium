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
  (String?, String?)? _ongoingCheckTarget;

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
    final serverId = multiServerState.activeServerId;
    final nodeId = _activeNodeId;
    final existing = _ongoingCheck;
    // A check started for a different server or node is meaningless for the
    // current target; let it run (it discards its own result) and start a
    // fresh one rather than returning the stale future.
    if (existing != null && _ongoingCheckTarget == (serverId, nodeId)) {
      return existing;
    }
    _ongoingCheckTarget = (serverId, nodeId);
    final check = _doCheck().whenComplete(() {
      // A check for a newer target may already have replaced this one.
      if (_ongoingCheckTarget == (serverId, nodeId)) {
        _ongoingCheck = null;
        _ongoingCheckTarget = null;
      }
    });
    _ongoingCheck = check;
    return check;
  }

  Future<void> _doCheck() async {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final api = this.api;
    final profileId = multiServerState.activeServerId;
    final nodeId = _activeNodeId;
    // /healthz is public, so a node-bound check would report "connected"
    // even when the satellite rejects the federation token. Probe an
    // authenticated endpoint instead so the whole proxy path is exercised.
    var ok = nodeId == null
        ? await api.checkHealth()
        : await _probeNode(api);
    var authFailed = false;
    if (ok && multiServerState.activeProfile?.isLocal == true) {
      // /healthz is public, so also prove the bundled token still
      // authenticates; otherwise a stale token looks "connected". This
      // probes the hub itself: a node-bound me() would blame a satellite's
      // auth problem on the bundled server and restart it in a loop.
      try {
        await hubApi.me();
      } catch (_) {
        ok = false;
        authFailed = true;
      }
    }
    // A server or node switch during the check makes the result meaningless
    // for the new target; drop it. The switch's own load path re-checks
    // anyway.
    if (multiServerState.activeServerId != profileId ||
        _activeNodeId != nodeId) {
      return;
    }
    final version = ok ? await api.serverVersion() : null;
    // The version fetch above is another suspension point; re-check before
    // applying anything so a switch during it cannot leak the old target's
    // status into the new one.
    if (multiServerState.activeServerId != profileId ||
        _activeNodeId != nodeId) {
      return;
    }

    final next = ok ? ConnectionStatus.connected : ConnectionStatus.disconnected;
    final recovered =
        _connectionStatus != ConnectionStatus.connected &&
        next == ConnectionStatus.connected;
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
    if (recovered) {
      // A dead SSE socket does not always report an error, so reopen the
      // lifecycle stream on the disconnected -> connected transition; the
      // fresh snapshot resyncs anything missed while away.
      _restartRunEvents();
    }
    // Node online flags age with each heartbeat; refresh them on the health
    // tick. When a satellite is selected this also runs while it is down —
    // the check fails through the proxy but the hub still answers the list.
    if (ok || _activeNodeId != null) {
      unawaited(refreshFederationNodes());
    }
    if (_connectionStatus == ConnectionStatus.connected) {
      _onConnectionRestored();
    }
  }

  /// Probe the selected satellite through the hub proxy. [ApiService.me]
  /// needs auth on the satellite, so a rejected federation token or a dead
  /// proxy route both read as disconnected.
  Future<bool> _probeNode(ApiService api) async {
    try {
      await api.me();
      return true;
    } catch (_) {
      return false;
    }
  }
}
