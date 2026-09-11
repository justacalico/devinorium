import 'local_server_types.dart';

/// Stub for platforms that cannot spawn the bundled server (web, mobile,
/// tests). Always reports unsupported.
class LocalServerManager {
  LocalServerManager();

  /// A manager that never spawns anything. Used by [AppState.test].
  factory LocalServerManager.disabled() => LocalServerManager();

  bool get isSupported => false;

  /// Called when the spawned server process exits unexpectedly.
  void Function(int exitCode)? onExit;

  Future<LocalServerEndpoint?> ensureRunning() async => null;

  Future<void> stop() async {}

  void dispose() {}
}
