/// No-op quit interception for web and other non-desktop targets.
Future<void> installQuitHandler(
  Future<void> Function() shutdown, {
  void Function(int exitCode) exitProcess = _noopExit,
  Duration cleanupTimeout = const Duration(seconds: 5),
}) async {}

void _noopExit(int exitCode) {}
