import 'package:flutter/foundation.dart' show TargetPlatform;

/// One entry in the "Open in" menu: an installed desktop editor or the OS
/// file manager. The catalog is ported from t3code's `EDITORS` list
/// (packages/contracts/src/editor.ts).
class EditorApp {
  /// Stable id, persisted as the user's preferred editor.
  final String id;

  /// Human-readable name shown in the menu and tooltips.
  final String label;

  /// Executable names tried in order on PATH and inside install dirs.
  /// Empty for pseudo-entries such as the file manager.
  final List<String> commands;

  /// Extra arguments prepended to the target path
  /// (e.g. `kiro ide <dir>` opens Kiro's IDE instead of its agent CLI).
  final List<String> baseArgs;

  /// JetBrains IDEs install under versioned Toolbox bundles and launch with
  /// `--line/--column` rather than `--goto`, so detection and launches take a
  /// different path.
  final bool isJetBrains;

  /// macOS `.app` display names used for bundle lookups; defaults to [label].
  final List<String> installNames;

  /// The pseudo-entry that opens the OS file manager instead of an editor.
  final bool isFileManager;

  const EditorApp({
    required this.id,
    required this.label,
    this.commands = const [],
    this.baseArgs = const [],
    this.isJetBrains = false,
    this.installNames = const [],
    this.isFileManager = false,
  });

  /// The display name of the app bundle on macOS / install folder on Windows.
  List<String> get bundleNames =>
      installNames.isNotEmpty ? installNames : [label];
}

/// Editor catalog in menu order, ported from t3code.
const List<EditorApp> kEditorCatalog = [
  EditorApp(
    id: 'cursor',
    label: 'Cursor',
    commands: ['cursor'],
    baseArgs: ['--classic'],
  ),
  EditorApp(id: 'trae', label: 'Trae', commands: ['trae']),
  EditorApp(id: 'kiro', label: 'Kiro', commands: ['kiro'], baseArgs: ['ide']),
  EditorApp(
    id: 'vscode',
    label: 'VS Code',
    commands: ['code'],
    installNames: ['Visual Studio Code'],
  ),
  EditorApp(
    id: 'vscode-insiders',
    label: 'VS Code Insiders',
    commands: ['code-insiders'],
    installNames: ['Visual Studio Code - Insiders'],
  ),
  EditorApp(id: 'vscodium', label: 'VSCodium', commands: ['codium']),
  EditorApp(id: 'zed', label: 'Zed', commands: ['zed', 'zeditor']),
  EditorApp(
    id: 'antigravity',
    label: 'Antigravity',
    // `agy` is the standalone Antigravity CLI, not the IDE. The IDE bundle
    // ships `antigravity-ide`, so it comes first for install-folder lookups.
    commands: ['antigravity-ide', 'agy-ide'],
    installNames: ['Antigravity IDE'],
  ),
  EditorApp(
    id: 'idea',
    label: 'IntelliJ IDEA',
    commands: ['idea'],
    isJetBrains: true,
    installNames: [
      'IntelliJ IDEA',
      'IntelliJ IDEA CE',
      'IntelliJ IDEA Ultimate',
    ],
  ),
  EditorApp(id: 'aqua', label: 'Aqua', commands: ['aqua'], isJetBrains: true),
  EditorApp(
    id: 'clion',
    label: 'CLion',
    commands: ['clion'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'datagrip',
    label: 'DataGrip',
    commands: ['datagrip'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'dataspell',
    label: 'DataSpell',
    commands: ['dataspell'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'goland',
    label: 'GoLand',
    commands: ['goland'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'phpstorm',
    label: 'PhpStorm',
    commands: ['phpstorm'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'pycharm',
    label: 'PyCharm',
    commands: ['pycharm'],
    isJetBrains: true,
    installNames: ['PyCharm', 'PyCharm CE'],
  ),
  EditorApp(
    id: 'rider',
    label: 'Rider',
    commands: ['rider'],
    isJetBrains: true,
    installNames: ['Rider', 'JetBrains Rider'],
  ),
  EditorApp(
    id: 'rubymine',
    label: 'RubyMine',
    commands: ['rubymine'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'rustrover',
    label: 'RustRover',
    commands: ['rustrover'],
    isJetBrains: true,
  ),
  EditorApp(
    id: 'webstorm',
    label: 'WebStorm',
    commands: ['webstorm'],
    isJetBrains: true,
  ),
  EditorApp(id: 'file-manager', label: 'File Manager', isFileManager: true),
];

/// The label for the OS file manager differs per platform (Finder on macOS,
/// File Explorer on Windows).
String fileManagerLabel(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS => 'Finder',
  TargetPlatform.windows => 'File Explorer',
  _ => 'File Manager',
};

/// Detects installed desktop editors and launches directories in them.
///
/// Only meaningful on desktop builds talking to the bundled local server:
/// remote servers' paths are not on this machine, and web/mobile builds
/// cannot spawn processes.
abstract class EditorLauncher {
  /// Whether this platform can launch external editors at all.
  bool get isSupported;

  /// The detected editors, in catalog order. Empty when nothing usable was
  /// found (or the platform is unsupported).
  Future<List<EditorApp>> detectEditors();

  /// Open [path] in the editor identified by [editorId] (or the file manager
  /// pseudo-entry). Returns false when the editor is unavailable or the
  /// launch failed.
  Future<bool> open(String path, String editorId);
}
