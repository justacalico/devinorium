import 'package:devinorium_frontend/services/editor_launcher_io.dart';
import 'package:devinorium_frontend/services/editor_launcher_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _SpawnCall = ({String command, List<String> args, bool runInShell});

class _SpawnRecorder {
  final calls = <_SpawnCall>[];
  bool fails = false;

  Future<void> call(
    String command,
    List<String> args, {
    bool runInShell = false,
  }) {
    calls.add((command: command, args: args, runInShell: runInShell));
    if (fails) throw StateError('spawn failed');
    return Future.value();
  }
}

EditorLauncherService _launcher({
  required String os,
  Map<String, String> env = const {},
  Set<String> executables = const {},
  Map<String, List<String>> dirs = const {},
  _SpawnRecorder? spawn,
  Future<bool> Function()? directoryHandlerProbe,
}) {
  return EditorLauncherService(
    operatingSystem: os,
    environment: env,
    canExecute: executables.contains,
    listDir: (dir) => dirs[dir] ?? const [],
    spawn: (command, args, {bool runInShell = false}) =>
        (spawn ?? _SpawnRecorder())(command, args, runInShell: runInShell),
    directoryHandlerProbe: directoryHandlerProbe ?? () async => true,
  );
}

Future<List<String>> _ids(EditorLauncherService launcher) async =>
    (await launcher.detectEditors()).map((e) => e.id).toList();

void main() {
  group('EditorLauncherService.isSupported', () {
    test('is true on desktop platforms only', () {
      for (final os in ['linux', 'macos', 'windows']) {
        expect(_launcher(os: os).isSupported, isTrue, reason: os);
      }
      for (final os in ['android', 'ios', 'fuchsia']) {
        expect(_launcher(os: os).isSupported, isFalse, reason: os);
      }
    });
  });

  group('detection', () {
    test('finds editors on PATH in catalog order', () async {
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin', 'DISPLAY': ':0'},
        executables: {
          '/usr/bin/code',
          '/usr/bin/zed',
          '/usr/bin/xdg-open',
          '/usr/bin/xdg-mime',
        },
      );
      expect(await _ids(launcher), ['vscode', 'zed', 'file-manager']);
    });

    test('returns empty when nothing is installed', () async {
      // No DISPLAY, so the file manager is unusable on Linux too.
      final launcher = _launcher(os: 'linux', env: {'PATH': '/usr/bin'});
      expect(await launcher.detectEditors(), isEmpty);
    });

    test('tries every command alias', () async {
      // Zed ships as `zeditor` on some distros.
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '/opt/bin'},
        executables: {'/opt/bin/zeditor'},
      );
      expect(await _ids(launcher), ['zed']);
    });

    test('caches the probe', () async {
      var listCalls = 0;
      final launcher = EditorLauncherService(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/me'},
        canExecute: (_) => false,
        listDir: (dir) {
          listCalls++;
          return const [];
        },
      );
      await launcher.detectEditors();
      final first = listCalls;
      await launcher.detectEditors();
      expect(listCalls, first);
    });
  });

  group('macOS install dirs', () {
    Map<String, List<String>> apps(List<String> bundles) => {
      '/Applications': bundles,
      '/Users/me/Applications': const [],
    };

    test('resolves VS Code bundles to their bin shim', () async {
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        dirs: apps([
          'Visual Studio Code.app',
          'Visual Studio Code - Insiders.app',
        ]),
        executables: {
          '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
          '/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders',
        },
      );
      expect(await _ids(launcher), [
        'vscode',
        'vscode-insiders',
        'file-manager',
      ]);
    });

    test('a different product cannot steal another bundle name', () async {
      // `Visual Studio Code - Insiders.app` is not `Visual Studio Code.app`.
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        dirs: apps(['Visual Studio Code - Insiders.app']),
        executables: {
          '/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders',
        },
      );
      expect(await _ids(launcher), ['vscode-insiders', 'file-manager']);
    });

    test('accepts versioned JetBrains Toolbox bundles', () async {
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        dirs: apps(['IntelliJ IDEA 2026.1.4.app']),
        executables: {
          '/Applications/IntelliJ IDEA 2026.1.4.app/Contents/MacOS/idea',
        },
      );
      expect(await _ids(launcher), ['idea', 'file-manager']);
    });

    test('rejects bundles whose suffix is not a version', () async {
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        dirs: apps(['IntelliJ IDEA Beta.app']),
        executables: {
          '/Applications/IntelliJ IDEA Beta.app/Contents/MacOS/idea',
        },
      );
      expect(await _ids(launcher), isNot(contains('idea')));
    });

    test('finds JetBrains Toolbox scripts', () async {
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        dirs: apps(const []),
        executables: {
          '/Users/me/Library/Application Support/JetBrains/Toolbox/scripts/goland',
        },
      );
      expect(await _ids(launcher), ['goland', 'file-manager']);
    });
  });

  group('windows install dirs', () {
    test('resolves VS Code under Program Files', () async {
      final launcher = _launcher(
        os: 'windows',
        env: {
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          'ProgramFiles': r'C:\Program Files',
        },
        executables: {
          r'C:\Program Files\Microsoft VS Code\resources/app/bin\code.cmd',
        },
      );
      expect(await _ids(launcher), ['vscode', 'file-manager']);
    });

    test('finds JetBrains Toolbox scripts', () async {
      final launcher = _launcher(
        os: 'windows',
        env: {'LOCALAPPDATA': r'C:\Users\me\AppData\Local'},
        executables: {
          r'C:\Users\me\AppData\Local\JetBrains/Toolbox/scripts\rider.cmd',
        },
      );
      expect(await _ids(launcher), ['rider', 'file-manager']);
    });
  });

  group('linux install dirs', () {
    test('checks well-known bin dirs beyond PATH', () async {
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '', 'HOME': '/home/me'},
        executables: {'/snap/bin/code'},
      );
      expect(await _ids(launcher), ['vscode']);
    });

    test('checks the Toolbox scripts dir under XDG_DATA_HOME', () async {
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '', 'HOME': '/home/me', 'XDG_DATA_HOME': '/xdg'},
        executables: {'/xdg/JetBrains/Toolbox/scripts/webstorm'},
      );
      expect(await _ids(launcher), ['webstorm']);
    });
  });

  group('file manager', () {
    test('linux needs a graphical session and xdg-open', () async {
      final noDisplay = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin'},
        executables: {'/usr/bin/xdg-open', '/usr/bin/xdg-mime'},
      );
      expect(await _ids(noDisplay), isNot(contains('file-manager')));

      final wayland = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin', 'WAYLAND_DISPLAY': 'wayland-1'},
        executables: {'/usr/bin/xdg-open', '/usr/bin/xdg-mime'},
      );
      expect(await _ids(wayland), ['file-manager']);
    });

    test('macos and windows always have one', () async {
      expect(await _ids(_launcher(os: 'macos')), ['file-manager']);
      expect(await _ids(_launcher(os: 'windows')), ['file-manager']);
    });

    test('is hidden without an inode/directory MIME handler', () async {
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin', 'DISPLAY': ':0'},
        executables: {'/usr/bin/xdg-open', '/usr/bin/xdg-mime'},
        directoryHandlerProbe: () async => false,
      );
      expect(await _ids(launcher), isNot(contains('file-manager')));
    });
  });

  group('open', () {
    test('launches the resolved command with base args and path', () async {
      final spawn = _SpawnRecorder();
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin'},
        executables: {'/usr/bin/cursor'},
        spawn: spawn,
      );
      expect(await launcher.open('/repo', 'cursor'), isTrue);
      expect(spawn.calls.single.command, '/usr/bin/cursor');
      // Cursor's `--classic` base arg keeps file opens away from the agents window.
      expect(spawn.calls.single.args, ['--classic', '/repo']);
      expect(spawn.calls.single.runInShell, isFalse);
    });

    test(
      'kiro drops its `ide` arg when launched from a macOS bundle',
      () async {
        final spawn = _SpawnRecorder();
        final launcher = _launcher(
          os: 'macos',
          env: {'HOME': '/Users/me'},
          dirs: {
            '/Applications': ['Kiro.app'],
            '/Users/me/Applications': const [],
          },
          executables: {
            '/Applications/Kiro.app/Contents/Resources/app/bin/kiro',
          },
          spawn: spawn,
        );
        await launcher.detectEditors();
        expect(await launcher.open('/repo', 'kiro'), isTrue);
        expect(spawn.calls.single.args, ['/repo']);
      },
    );

    test(
      'windows PATH-resolved .cmd spawns the resolved path via shell',
      () async {
        final spawn = _SpawnRecorder();
        final launcher = _launcher(
          os: 'windows',
          env: {
            'PATH': r'C:\Users\me\AppData\Local\Programs\Microsoft VS Code\bin',
            'PATHEXT': '.COM;.EXE;.BAT;.CMD',
          },
          executables: {
            r'C:\Users\me\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd',
          },
          spawn: spawn,
        );
        // Detected via PATH, but the launch must use the resolved .cmd path —
        // CreateProcess cannot run `code` directly when only code.cmd exists.
        expect(await _ids(launcher), contains('vscode'));
        expect(await launcher.open(r'C:\repo', 'vscode'), isTrue);
        expect(
          spawn.calls.single.command,
          r'C:\Users\me\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd',
        );
        expect(spawn.calls.single.runInShell, isTrue);
      },
    );

    test('windows .cmd shims run through the shell', () async {
      final spawn = _SpawnRecorder();
      final launcher = _launcher(
        os: 'windows',
        env: {'ProgramFiles': r'C:\Program Files'},
        executables: {
          r'C:\Program Files\Microsoft VS Code\resources/app/bin\code.cmd',
        },
        spawn: spawn,
      );
      expect(await launcher.open(r'C:\repo', 'vscode'), isTrue);
      expect(spawn.calls.single.runInShell, isTrue);
    });

    test('opens the platform file manager', () async {
      final spawn = _SpawnRecorder();
      final launcher = _launcher(
        os: 'macos',
        env: {'HOME': '/Users/me'},
        spawn: spawn,
      );
      expect(await launcher.open('/repo', 'file-manager'), isTrue);
      expect(spawn.calls.single.command, 'open');
      expect(spawn.calls.single.args, ['/repo']);
    });

    test('returns false for unknown or missing editors', () async {
      final launcher = _launcher(os: 'linux', env: {'PATH': '/usr/bin'});
      expect(await launcher.open('/repo', 'nope'), isFalse);
      expect(await launcher.open('/repo', 'vscode'), isFalse);
      expect(await launcher.open('/repo', 'file-manager'), isFalse);
      expect(await launcher.open('', 'vscode'), isFalse);
    });

    test('returns false when spawning throws', () async {
      final spawn = _SpawnRecorder()..fails = true;
      final launcher = _launcher(
        os: 'linux',
        env: {'PATH': '/usr/bin'},
        executables: {'/usr/bin/code'},
        spawn: spawn,
      );
      expect(await launcher.open('/repo', 'vscode'), isFalse);
    });

    test('unsupported platforms never spawn', () async {
      final spawn = _SpawnRecorder();
      final launcher = _launcher(os: 'android', spawn: spawn);
      expect(await launcher.open('/repo', 'vscode'), isFalse);
      expect(spawn.calls, isEmpty);
    });
  });

  group('fileManagerLabel', () {
    test('names the OS file manager', () {
      expect(fileManagerLabel(TargetPlatform.macOS), 'Finder');
      expect(fileManagerLabel(TargetPlatform.windows), 'File Explorer');
      expect(fileManagerLabel(TargetPlatform.linux), 'File Manager');
    });
  });

  test('catalog has stable unique ids', () {
    final ids = kEditorCatalog.map((e) => e.id).toSet();
    expect(ids.length, kEditorCatalog.length);
    expect(ids, contains('vscode'));
    expect(ids, contains('file-manager'));
  });
}
