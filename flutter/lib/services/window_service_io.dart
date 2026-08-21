import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Initializes window_manager on desktop and hides the native title bar
/// so the app can draw its own.
Future<void> initializeWindow() async {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final windowOptions = WindowOptions(
    size: const Size(1280, 720),
    minimumSize: const Size(400, 300),
    center: true,
    title: 'Devinorium',
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
