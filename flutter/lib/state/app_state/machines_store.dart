part of 'package:devinorium_frontend/state/app_state.dart';

mixin MachinesStore on AppStateBase {
  @override
  List<Machine> _machines = [];
  @override
  int _machinesSeq = 0;

  @override
  List<Machine> get machines => _machines;

  /// Pull `GET /api/machines` for the active server. A missing endpoint
  /// (older server) just leaves the section and `@` picker empty. The seq
  /// guard keeps a response from the previous server from landing after a
  /// switch.
  @override
  Future<void> loadMachines() async {
    if (multiServerState.activeApi == null) return;
    final seq = ++_machinesSeq;
    try {
      final machines = await api.machines();
      if (seq != _machinesSeq) return;
      _machines = machines;
      notifyListeners();
    } catch (_) {
      // Keep a previously loaded list: one transient failure should not
      // empty the picker.
    }
  }

  /// Add a machine (owner only). Returns an error string on failure.
  @override
  Future<String?> createMachine({
    required String name,
    required String host,
    required int port,
    String? password,
  }) => _mutateMachines(
    () => api.createMachine(
      name: name,
      host: host,
      port: port,
      password: password,
    ),
  );

  /// Edit a machine (owner only). Null fields keep their stored values;
  /// [clearPassword] drops the stored VNC password. Returns an error string
  /// on failure.
  @override
  Future<String?> updateMachine(
    int id, {
    String? name,
    String? host,
    int? port,
    String? password,
    bool clearPassword = false,
  }) => _mutateMachines(
    () => api.updateMachine(
      id,
      name: name,
      host: host,
      port: port,
      password: clearPassword
          ? ''
          : (password == null || password.isEmpty ? null : password),
    ),
  );

  /// Remove a machine (owner only). Returns an error string on failure.
  @override
  Future<String?> deleteMachine(int id) =>
      _mutateMachines(() => api.deleteMachine(id));

  Future<String?> _mutateMachines(Future<Object?> Function() op) async {
    final seq = _machinesSeq;
    try {
      await op();
      await loadMachines();
      return null;
    } on ApiException catch (e) {
      return seq != _machinesSeq ? null : e.message;
    } catch (e) {
      return seq != _machinesSeq ? null : '$e';
    }
  }

  /// Probe the machine's VNC endpoint (owner only). The result carries the
  /// framebuffer geometry on success or the failure string; transport-level
  /// errors are folded into a failed result so the UI has one shape.
  @override
  Future<MachineTestResult> testMachine(int id) async {
    try {
      return await api.testMachine(id);
    } on ApiException catch (e) {
      return MachineTestResult(ok: false, error: e.message);
    } catch (e) {
      return MachineTestResult(ok: false, error: '$e');
    }
  }
}
