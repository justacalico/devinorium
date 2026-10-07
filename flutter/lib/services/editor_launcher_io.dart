import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/debug_log.dart';
import 'editor_launcher_types.dart';

/// A resolved editor launch: the executable (an absolute path, found either
/// on PATH or in an install location) plus the arguments that precede the
/// target path.
typedef EditorCommand = ({String command, List<String> baseArgs});

/// Signature for spawning external processes. Injectable so tests can record
/// launches instead of starting real editors.
typedef EditorProcessStarter =
    Future<void> Function(
      String command,
      List<String> arguments, {
      bool runInShell,
    });

/// Launches directories in editors installed on this machine.
///
/// Ported from t3code's `resolveEditorCommand`/`externalLauncher`: each
/// editor is first looked up on PATH, then inside platform-specific install
/// locations (macOS `.app` bundles including versioned JetBrains Toolbox
/// installs, Windows Program Files folders, Linux bin dirs). Launches are
/// detached so the editor outlives the app.
class EditorLauncherService implements EditorLauncher {
  EditorLauncherService({
    Map<String, String>? environment,
    String? operatingSystem,
    bool Function(String path)? canExecute,
    List<String> Function(String dir)? listDir,
    EditorProcessStarter? spawn,
    Future<bool> Function()? directoryHandlerProbe,
  }) : _environment = environment ?? Platform.environment,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _canExecute = canExecute ?? _defaultCanExecute,
       _listDir = listDir ?? _defaultListDir,
       _spawn = spawn ?? _defaultSpawn,
       _directoryHandlerProbe =
           directoryHandlerProbe ?? _defaultDirectoryHandlerProbe;

  final Map<String, String> _environment;
  final String _operatingSystem;
  final bool Function(String path) _canExecute;
  final List<String> Function(String dir) _listDir;
  final EditorProcessStarter _spawn;
  final Future<bool> Function() _directoryHandlerProbe;

  /// Resolved command per editor id, filled by [detectEditors] so [open]
  /// does not re-probe the filesystem.
  final Map<String, EditorCommand> _resolved = {};
  Future<List<EditorApp>>? _detected;

  /// Detection only makes sense on desktop platforms; mobile builds ship the
  /// dart:io implementation too, so gate on the OS name here.
  @override
  bool get isSupported => switch (_operatingSystem) {
    'linux' || 'macos' || 'windows' => true,
    _ => false,
  };

  String? get _home =>
      _nonEmpty(_environment['HOME'] ?? _environment['USERPROFILE']);

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  @override
  Future<List<EditorApp>> detectEditors() {
    return _detected ??= _detect();
  }

  Future<List<EditorApp>> _detect() async {
    if (!isSupported) return const [];
    try {
      final found = <EditorApp>[];
      for (final editor in kEditorCatalog) {
        if (editor.isFileManager) {
          if (await _fileManagerCommand() != null) found.add(editor);
          continue;
        }
        final resolved = _resolveEditorCommand(editor);
        if (resolved != null) {
          _resolved[editor.id] = resolved;
          found.add(editor);
        }
      }
      return found;
    } catch (e) {
      debugLogFailure('editorLauncher.detect', e);
      return const [];
    }
  }

  @override
  Future<bool> open(String path, String editorId) async {
    if (!isSupported || path.isEmpty) return false;
    if (editorId == 'file-manager') {
      final command = await _fileManagerCommand();
      if (command == null) return false;
      return _launch(command, [path]);
    }
    final editor = kEditorCatalog.where((e) => e.id == editorId).firstOrNull;
    if (editor == null) return false;
    // Re-resolve when open() is called without a prior detectEditors() (or
    // when the editor was installed after detection ran).
    final resolved = _resolved[editor.id] ?? _resolveEditorCommand(editor);
    if (resolved == null) return false;
    _resolved[editor.id] = resolved;
    return _launch(resolved.command, [...resolved.baseArgs, path]);
  }

  Future<bool> _launch(String command, List<String> args) async {
    try {
      // Windows .cmd/.bat shims are not directly executable: route them
      // through cmd.exe like Node's `shell: true` spawn.
      final lower = command.toLowerCase();
      final needsShell =
          _operatingSystem == 'windows' &&
          (lower.endsWith('.cmd') || lower.endsWith('.bat'));
      await _spawn(command, args, runInShell: needsShell);
      return true;
    } catch (e) {
      debugLogFailure('editorLauncher.launch', '$command $args: $e');
      return false;
    }
  }

  /// The platform's file-manager command, or null when there is no graphical
  /// session to open it in. Mirrors t3code's `fileManagerCommandForPlatform`.
  Future<String?> _fileManagerCommand() async {
    switch (_operatingSystem) {
      case 'macos':
        return 'open';
      case 'windows':
        return 'explorer';
      case 'linux':
        final hasSession =
            _nonEmpty(_environment['DISPLAY']) != null ||
            _nonEmpty(_environment['WAYLAND_DISPLAY']) != null;
        if (!hasSession || _pathLookup('xdg-open') == null) return null;
        // xdg-open exits nonzero without an `inode/directory` MIME handler
        // after the launcher has already detached — a silent no-op — so the
        // entry is only offered when a handler exists.
        return await _hasLinuxDirectoryHandler() ? 'xdg-open' : null;
      default:
        return null;
    }
  }

  /// Find an executable for [editor]: PATH first (so user shims win), then
  /// platform-specific install locations. PATH hits keep the resolved
  /// absolute path — on Windows the shim is a `.cmd`/`.bat` that
  /// CreateProcess cannot run directly, and [_launch] needs the extension to
  /// know it must go through the shell.
  EditorCommand? _resolveEditorCommand(EditorApp editor) {
    if (editor.commands.isEmpty) return null;
    for (final command in editor.commands) {
      final resolved = _pathLookup(command);
      if (resolved != null) {
        return (command: resolved, baseArgs: editor.baseArgs);
      }
    }
    for (final candidate in _installCandidates(editor)) {
      if (_canExecute(candidate)) {
        // Kiro's installed binary is already the IDE; only its PATH shim
        // needs the `ide` subcommand (t3code behavior on macOS/Windows).
        final stripArgs =
            editor.id == 'kiro' &&
            (_operatingSystem == 'macos' || _operatingSystem == 'windows');
        return (
          command: candidate,
          baseArgs: stripArgs ? const [] : editor.baseArgs,
        );
      }
    }
    return null;
  }

  /// Absolute-path candidates in install locations beyond PATH, ported from
  /// t3code's per-platform lookups.
  List<String> _installCandidates(EditorApp editor) {
    final command = editor.commands.first;
    final names = editor.bundleNames;
    final candidates = <String>[];
    final home = _home;

    switch (_operatingSystem) {
      case 'macos':
        final ctx = p.posix;
        final roots = [
          if (home != null) ctx.join(home, 'Applications'),
          '/Applications',
        ];
        for (final root in roots) {
          // JetBrains Toolbox installs bundles named `<name> <version>.app`,
          // so accept exact names plus versioned entries.
          final entries = _listDir(root);
          final bundles = <String>{for (final n in names) '$n.app'};
          for (final entry in entries) {
            if (names.any(
              (n) => entry == '$n.app' || _isVersionedBundle(entry, n),
            )) {
              bundles.add(entry);
            }
          }
          for (final bundle in bundles) {
            final contents = ctx.join(root, bundle, 'Contents');
            if (editor.isJetBrains || editor.id == 'zed') {
              candidates.add(
                ctx.join(
                  contents,
                  'MacOS',
                  editor.id == 'zed' ? 'cli' : command,
                ),
              );
            } else {
              candidates.add(ctx.join(contents, 'Resources/app/bin', command));
              candidates.add(ctx.join(contents, 'Resources/app/bin/code'));
            }
          }
        }
        if (home != null && editor.isJetBrains) {
          candidates.add(
            ctx.join(
              home,
              'Library/Application Support/JetBrains/Toolbox/scripts',
              command,
            ),
          );
        }
      case 'windows':
        final ctx = p.windows;
        final roots = [
          if (_nonEmpty(_environment['LOCALAPPDATA']) != null)
            ctx.join(_environment['LOCALAPPDATA']!, 'Programs'),
          ?_nonEmpty(_environment['ProgramFiles']),
          ?_nonEmpty(_environment['ProgramFiles(x86)']),
          ?_nonEmpty(_environment['ProgramW6432']),
        ];
        if (editor.isJetBrains) {
          final localAppData = _nonEmpty(_environment['LOCALAPPDATA']);
          if (localAppData != null) {
            candidates.add(
              ctx.join(
                localAppData,
                'JetBrains/Toolbox/scripts',
                '$command.cmd',
              ),
            );
          }
          for (final root in roots) {
            for (final directory in [root, ctx.join(root, 'JetBrains')]) {
              for (final entry in _listDir(directory)) {
                if (names.any((n) => entry == n || entry.startsWith('$n '))) {
                  candidates.add(
                    ctx.join(directory, entry, 'bin', '${command}64.exe'),
                  );
                  candidates.add(
                    ctx.join(directory, entry, 'bin', '$command.exe'),
                  );
                }
              }
            }
          }
        } else {
          final name = switch (editor.id) {
            'vscode' => 'Microsoft VS Code',
            'vscode-insiders' => 'Microsoft VS Code Insiders',
            _ => editor.label,
          };
          for (final root in roots) {
            candidates.addAll([
              ctx.join(root, name, 'resources/app/bin', '$command.cmd'),
              ctx.join(root, name, 'resources/app/bin/code.cmd'),
              ctx.join(root, name, 'bin', '$command.cmd'),
              ctx.join(root, name, 'bin/code.cmd'),
            ]);
            if (editor.id == 'zed') {
              candidates.addAll([
                ctx.join(root, name, 'bin', 'zed.exe'),
                ctx.join(root, name, 'zed.exe'),
              ]);
            }
          }
        }
      case 'linux':
        final ctx = p.posix;
        final dirs = [
          if (home != null) ctx.join(home, '.local/bin'),
          '/usr/local/bin',
          '/usr/bin',
          '/snap/bin',
        ];
        if (editor.isJetBrains) {
          final dataHome =
              _nonEmpty(_environment['XDG_DATA_HOME']) ??
              (home != null ? ctx.join(home, '.local/share') : null);
          if (dataHome != null) {
            dirs.add(ctx.join(dataHome, 'JetBrains/Toolbox/scripts'));
          }
        }
        for (final dir in dirs) {
          for (final name in editor.commands) {
            candidates.add(ctx.join(dir, name));
          }
        }
    }
    return candidates;
  }

  /// True for `<name> <version>.app` where the version is digits and dots
  /// (`IntelliJ IDEA 2026.1.4.app`). A plain prefix match would let one
  /// editor steal another's bundle, e.g. stable VS Code resolving to
  /// `Visual Studio Code - Insiders.app`.
  static bool _isVersionedBundle(String entry, String name) {
    if (!entry.startsWith('$name ') || !entry.endsWith('.app')) return false;
    final version = entry.substring(
      name.length + 1,
      entry.length - '.app'.length,
    );
    return RegExp(r'^\d[\d.]*$').hasMatch(version);
  }

  /// PATH lookup for a bare command. On Windows, PATHEXT extensions are
  /// appended when the command has none.
  String? _pathLookup(String command) {
    final separator = _operatingSystem == 'windows' ? ';' : ':';
    final pathEnv =
        _environment['PATH'] ?? _environment['Path'] ?? _environment['path'];
    if (pathEnv == null || pathEnv.isEmpty) return null;
    final names = _commandFileNames(command);
    for (final rawDir in pathEnv.split(separator)) {
      var dir = rawDir.trim();
      if (dir.length > 1 && dir.startsWith('"') && dir.endsWith('"')) {
        dir = dir.substring(1, dir.length - 1);
      }
      if (dir.isEmpty) continue;
      for (final name in names) {
        final candidate = (_operatingSystem == 'windows' ? p.windows : p.posix)
            .join(dir, name);
        if (_canExecute(candidate)) return candidate;
      }
    }
    return null;
  }

  List<String> _commandFileNames(String command) {
    if (_operatingSystem != 'windows') return [command];
    final hasExt = p.windows.extension(command).isNotEmpty;
    if (hasExt) return [command];
    final pathext = _environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD';
    return [
      for (final ext in pathext.split(';'))
        if (ext.isNotEmpty) '$command${ext.toLowerCase()}',
      for (final ext in pathext.split(';'))
        if (ext.isNotEmpty) '$command${ext.toUpperCase()}',
    ];
  }

  /// Whether `xdg-mime` reports a default handler for directories. Kept
  /// injectable because the real check spawns a process.
  Future<bool> _hasLinuxDirectoryHandler() async {
    if (_pathLookup('xdg-mime') == null) return false;
    try {
      return await _directoryHandlerProbe();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultDirectoryHandlerProbe() async {
    try {
      final result = await Process.run('xdg-mime', [
        'query',
        'default',
        'inode/directory',
      ], stdoutEncoding: utf8).timeout(const Duration(seconds: 2));
      return result.exitCode == 0 &&
          (result.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static bool _defaultCanExecute(String path) {
    try {
      if (Platform.isWindows) return FileSystemEntity.isFileSync(path);
      final stat = FileStat.statSync(path);
      return stat.type == FileSystemEntityType.file &&
          stat.mode & 0x49 != 0; // any owner/group/other exec bit
    } catch (_) {
      return false;
    }
  }

  static List<String> _defaultListDir(String dir) {
    try {
      return Directory(
        dir,
      ).listSync(followLinks: false).map((e) => p.basename(e.path)).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _defaultSpawn(
    String command,
    List<String> arguments, {
    bool runInShell = false,
  }) async {
    await Process.start(
      command,
      arguments,
      mode: ProcessStartMode.detached,
      runInShell: runInShell,
    );
  }
}
