import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Routes every window close through Dart cleanup and exit(0).
///
/// Letting GTK destroy the last window runs an engine teardown path with a
/// use-after-free (flutter/flutter#193742): a pending FlTaskRunner timeout
/// can fire after the runner was finalized, so the process segfaults on the
/// way out and the OS reports a crash. Preventing the native close and
/// exiting ourselves keeps that code from ever running; the bundled server
/// is stopped by [shutdown] and would also die with our exit since it
/// watches stdin.
Future<void> installQuitHandler(
  Future<void> Function() shutdown, {
  void Function(int exitCode) exitProcess = exit,
  Duration cleanupTimeout = const Duration(seconds: 5),
}) async {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
    return;
  }
  var quitting = false;
  windowManager.addListener(
    _QuitListener(() async {
      // A second close gesture can arrive while cleanup is still in
      // flight; only shut down once.
      if (quitting) return;
      quitting = true;
      try {
        await shutdown().timeout(cleanupTimeout);
      } catch (_) {
        // Cleanup must never keep the window open.
      }
      exitProcess(0);
    }),
  );
  // initializeWindow() already sets this before the first show; repeat it so
  // the handler is self-contained for entrypoints that skip that setup.
  await windowManager.setPreventClose(true);
}

class _QuitListener with WindowListener {
  _QuitListener(this._onClose);

  final Future<void> Function() _onClose;

  @override
  void onWindowClose() => unawaited(_onClose());
}
