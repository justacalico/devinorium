import 'editor_launcher_types.dart';

/// Stub for platforms that cannot launch external editors (web).
/// Always reports unsupported so the "Open in" control stays hidden.
class EditorLauncherService implements EditorLauncher {
  EditorLauncherService();

  @override
  bool get isSupported => false;

  @override
  Future<List<EditorApp>> detectEditors() async => const [];

  @override
  Future<bool> open(String path, String editorId) async => false;
}
