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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final ok = await api.checkHealth();
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
    if (changed) {
      notifyListeners();
    }
    if (!ok && _healthTimer != null) {
      _reconnectTimer = Timer(const Duration(seconds: 2), checkConnection);
    }
    if (_connectionStatus == ConnectionStatus.connected) {
      _onConnectionRestored();
    }
  }
}
