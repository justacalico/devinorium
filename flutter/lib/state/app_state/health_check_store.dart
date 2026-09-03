part of 'package:devinorium_frontend/state/app_state.dart';

mixin HealthCheckStore on AppStateBase {
  @override
  ConnectionStatus _connectionStatus = ConnectionStatus.checking;
  @override
  String? _serverVersion;
  @override
  Timer? _healthTimer;
  @override
  ConnectionStatus get connectionStatus => _connectionStatus;
  @override
  String? get serverVersion => _serverVersion;
  @override
  void startHealthChecks() {
    _healthTimer?.cancel();
    checkConnection();
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      checkConnection();
    });
  }
  @override
  void stopHealthChecks() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }
  @override
  Future<void> checkConnection() async {
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
  }
}
