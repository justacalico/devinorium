import 'package:window_manager/window_manager.dart';

Future<void> startWindowDragging() => windowManager.startDragging();

Future<void> toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

Future<void> minimizeWindow() => windowManager.minimize();

Future<void> closeWindow() => windowManager.close();
