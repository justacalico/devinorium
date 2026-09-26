part of 'package:devinorium_frontend/state/app_state.dart';

mixin MachinesStore on AppStateBase {
  @override
  List<Machine> _machines = [];
  @override
  int _machinesSeq = 0;

  @override
  List<Machine> get machines => _machines;

  /// Pull `GET /api/machines` for the active server. Owner-only: machine
  /// references mint control grants, so non-owners keep an empty list
  /// and the `@` picker stays shut. The seq guard keeps a response from the
  /// previous server from landing after a switch.
  @override
  Future<void> loadMachines() async {
    if (multiServerState.activeApi == null || !isOwner) return;
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
    required String kind,
    required String host,
    required int port,
    String? sshUser,
    String? password,
    String? sshKey,
  }) => _mutateMachines(
    () => api.createMachine(
      name: name,
      kind: kind,
      host: host,
      port: port,
      sshUser: sshUser,
      password: password,
      sshKey: sshKey,
    ),
  );

  /// Edit a machine (owner only). Null fields keep their stored values;
  /// [clearPassword]/[clearSshKey] drop the stored secrets. Returns an
  /// error string on failure.
  @override
  Future<String?> updateMachine(
    int id, {
    String? name,
    String? kind,
    String? host,
    int? port,
    String? sshUser,
    String? password,
    String? sshKey,
    bool clearPassword = false,
    bool clearSshKey = false,
    bool resetFingerprint = false,
  }) => _mutateMachines(
    () => api.updateMachine(
      id,
      name: name,
      kind: kind,
      host: host,
      port: port,
      sshUser: sshUser,
      password: clearPassword
          ? ''
          : (password == null || password.isEmpty ? null : password),
      sshKey: clearSshKey
          ? ''
          : (sshKey == null || sshKey.trim().isEmpty ? null : sshKey),
      sshFingerprint: resetFingerprint ? '' : null,
    ),
  );

  /// Remove a machine (owner only). Returns an error string on failure.
  @override
  Future<String?> deleteMachine(int id) =>
      _mutateMachines(() => api.deleteMachine(id));

  Future<String?> _mutateMachines(Future<Object?> Function() op) async {
    try {
      await op();
      await loadMachines();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Probe the machine's endpoint (owner only). The result carries the
  /// framebuffer geometry (VNC) or remote hostname (SSH) on success, or
  /// the failure string; transport-level errors are folded into a failed
  /// result so the UI has one shape.
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
