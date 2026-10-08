import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/debug_log.dart';
import 'local_server_io.dart';
import 'multi_window_types.dart';

/// File-backed [MultiWindowStore] for desktop builds.
///
/// The marker lives next to `endpoint.json` in the per-user data directory
/// resolved by [LocalServerManager.dataDirPath], and the native runners
/// mirror that resolution to read it before the engine starts.
class MultiWindowPreference implements MultiWindowStore {
  MultiWindowPreference({
    String? operatingSystem,
    Map<String, String>? environment,
    this.dataDir,
    bool? supported,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _environment = environment ?? Platform.environment,
       _supported =
           supported ??
           checkSupported(operatingSystem ?? Platform.operatingSystem);

  /// A store that reports unsupported and never touches the filesystem.
  /// Used by [AppState.test] so tests stay hermetic.
  factory MultiWindowPreference.disabled() =>
      MultiWindowPreference(supported: false);

  final String _operatingSystem;
  final Map<String, String> _environment;
  final bool _supported;

  /// Optional override for the data directory (default: per-user app data).
  final String? dataDir;

  static bool checkSupported(String operatingSystem) =>
      operatingSystem == 'linux' || operatingSystem == 'windows';

  @override
  bool get isSupported => _supported;

  File get _markerFile => File(
    p.join(
      dataDir ?? LocalServerManager.dataDirPath(_operatingSystem, _environment),
      MultiWindowStore.markerFileName,
    ),
  );

  @override
  Future<bool> load() async {
    if (!isSupported) return false;
    return _markerFile.exists();
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!isSupported) return;
    final file = _markerFile;
    try {
      if (enabled) {
        await file.parent.create(recursive: true);
        // The server locks this directory down to 700 once it starts;
        // match that posture when the marker creates it first.
        await _makePrivate(file.parent);
        await file.writeAsString('1\n', flush: true);
      } else {
        try {
          await file.delete();
        } on FileSystemException {
          // Missing is fine; anything still present must surface so the
          // caller does not commit a state the runner will not see.
          if (await file.exists()) rethrow;
        }
      }
    } catch (e) {
      debugLogFailure('multiWindow.marker', e);
      rethrow;
    }
  }

  static Future<void> _makePrivate(Directory dir) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['700', dir.path]);
    } catch (_) {}
  }
}
