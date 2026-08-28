part of 'package:devinorium_frontend/state/app_state.dart';

mixin HealthCheckStore on AppStateBase {
  @override
  ConnectionStatus _connectionStatus = ConnectionStatus.checking;
  @override
  Timer? _healthTimer;
  @override
  ConnectionStatus get connectionStatus => _connectionStatus;
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
    final next = ok
        ? ConnectionStatus.connected
        : ConnectionStatus.disconnected;
    if (_connectionStatus != next) {
      _connectionStatus = next;
      notifyListeners();
    }
  }
}
