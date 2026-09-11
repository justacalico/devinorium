import 'local_server_types.dart';

/// Stub for platforms that cannot spawn the bundled server (web, mobile,
/// tests). Always reports unsupported.
class LocalServerManager implements LocalServerController {
  LocalServerManager();

  /// A manager that never spawns anything. Used by [AppState.test].
  factory LocalServerManager.disabled() => LocalServerManager();

  @override
  bool get isSupported => false;

  @override
  bool get hasBinary => false;

  @override
  LocalServerEndpoint? get endpoint => null;

  /// Called when the spawned server process exits unexpectedly.
  @override
  void Function(int exitCode)? onExit;

  @override
  Future<LocalServerEndpoint?> ensureRunning() async => null;

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}
