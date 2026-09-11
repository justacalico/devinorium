/// Connection details for the devinorium server bundled inside desktop
/// builds. The app spawns it on a random loopback port with a per-launch
/// bearer token, so the user never logs in but other local processes still
/// cannot call the API.
class LocalServerEndpoint {
  final String baseUrl;
  final String token;

  const LocalServerEndpoint({required this.baseUrl, required this.token});
}

/// The contract [AppState] depends on, implemented by both the real
/// (dart:io) manager and the stub so either can be swapped in by the
/// conditional export — or by a test fake.
abstract class LocalServerController {
  /// Whether this platform can run a bundled server.
  bool get isSupported;

  /// Whether a bundled server binary exists next to the app executable.
  /// Distinguishes "not packaged" (dev builds) from "failed to start".
  bool get hasBinary;

  /// The live endpoint, or `null` when no server is currently running.
  LocalServerEndpoint? get endpoint;

  /// Called when the spawned server exits on its own (crash or kill), but not
  /// after a deliberate [stop].
  void Function(int exitCode)? get onExit;
  set onExit(void Function(int exitCode)? callback);

  /// Start the bundled server if needed and return its endpoint, or `null`
  /// when unsupported or no bundled binary exists.
  Future<LocalServerEndpoint?> ensureRunning();

  /// Stop the bundled server. Safe to call when nothing is running.
  Future<void> stop();

  void dispose();
}
