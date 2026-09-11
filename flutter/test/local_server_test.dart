import 'dart:io';

import 'package:devinorium_frontend/services/local_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalServerManager', () {
    test('disabled manager is unsupported and never runs', () async {
      final manager = LocalServerManager.disabled();
      expect(manager.isSupported, isFalse);
      expect(await manager.ensureRunning(), isNull);
      manager.dispose();
    });

    test('binaryCandidates prefers the override then the bundled paths', () {
      final manager = LocalServerManager(
        supported: true,
        executablePath: '/app/runner/devinorium-app',
        environment: const {},
        binaryPath: '/x/devinorium',
      );
      final candidates = manager.binaryCandidates();
      expect(candidates[0], '/x/devinorium');
      expect(candidates[1], '/app/runner/server/devinorium');
      expect(candidates[2], '/app/runner/devinorium');
      manager.dispose();
    });

    test('binaryFileName adds .exe only on windows', () {
      expect(LocalServerManager.binaryFileName('linux'), 'devinorium');
      expect(LocalServerManager.binaryFileName('macos'), 'devinorium');
      expect(LocalServerManager.binaryFileName('windows'), 'devinorium.exe');
    });

    test('dataDirPath resolves a per-user directory on every platform', () {
      expect(
        LocalServerManager.dataDirPath('windows', {
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
        }),
        r'C:\Users\me\AppData\Local\devinorium',
      );
      expect(
        LocalServerManager.dataDirPath('macos', {'HOME': '/Users/me'}),
        '/Users/me/Library/Application Support/devinorium',
      );
      expect(
        LocalServerManager.dataDirPath('linux', {
          'XDG_DATA_HOME': '/data',
          'HOME': '/home/me',
        }),
        '/data/devinorium',
      );
      expect(
        LocalServerManager.dataDirPath('linux', {'HOME': '/home/me'}),
        '/home/me/.local/share/devinorium',
      );
      // No usable env at all falls back to a temp directory.
      expect(
        LocalServerManager.dataDirPath('linux', const {}),
        contains('devinorium'),
      );
    });

    test('generateToken returns 64 random hex characters', () {
      final a = LocalServerManager.generateToken();
      final b = LocalServerManager.generateToken();
      expect(a, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('ensureRunning returns null when no binary exists', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final manager = LocalServerManager(
        supported: true,
        executablePath: '${dir.path}/app/devinorium-app',
        environment: const {},
        dataDir: dir.path,
      );
      addTearDown(manager.dispose);
      expect(await manager.ensureRunning(), isNull);
    });

    Future<LocalServerManager> fakeManager({
      required Directory dir,
      ServerProcessStarter? spawnProcess,
      Future<bool> Function(Uri)? healthCheck,
      void Function(int)? onExit,
      List<Map<String, String>>? capturedEnv,
    }) async {
      final binary = File('${dir.path}/devinorium')..createSync();
      return LocalServerManager(
        supported: true,
        executablePath: '${dir.path}/app/runner',
        environment: const {},
        binaryPath: binary.path,
        dataDir: dir.path,
        spawnProcess: spawnProcess ??
            (exe, args, {required environment, required workingDirectory}) {
              capturedEnv?.add(environment);
              return Process.start('sleep', ['30']);
            },
        healthCheck: healthCheck ?? (_) async => true,
        onExit: onExit,
      );
    }

    test('ensureRunning spawns the server and returns its endpoint', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final capturedEnv = <Map<String, String>>[];
      final manager = await fakeManager(dir: dir, capturedEnv: capturedEnv);
      addTearDown(manager.dispose);

      final endpoint = await manager.ensureRunning();
      expect(endpoint, isNotNull);
      expect(endpoint!.baseUrl, matches(r'^http://127\.0\.0\.1:\d+$'));
      expect(endpoint.token, hasLength(64));

      final env = capturedEnv.single;
      expect(env['DEVINORIUM_LOCAL_TOKEN'], endpoint.token);
      expect(env['DEVINORIUM_HOST'], '127.0.0.1');
      expect(env['DEVINORIUM_PORT'], endpoint.baseUrl.split(':').last);
      expect(env['DEVINORIUM_DB_URL'], startsWith('sqlite:'));
      expect(env['DEVINORIUM_DB_URL'], contains(dir.path));
      expect(env['DEVINORIUM_SESSION_KEY'], hasLength(64));

      // A second call returns the same endpoint without respawning.
      expect(await manager.ensureRunning(), same(endpoint));
      expect(capturedEnv, hasLength(1));
    });

    test('ensureRunning returns null when the process dies at startup',
        () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      int? exitCode;
      final manager = await fakeManager(
        dir: dir,
        onExit: (code) => exitCode = code,
        spawnProcess:
            (exe, args, {required environment, required workingDirectory}) =>
                Process.start('sh', ['-c', 'exit 1']),
        healthCheck: (_) async => false,
      );
      addTearDown(manager.dispose);

      expect(await manager.ensureRunning(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exitCode, 1);
      expect(manager.endpoint, isNull);
    });

    test('ensureRunning returns null when spawn fails', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final manager = await fakeManager(
        dir: dir,
        spawnProcess:
            (exe, args, {required environment, required workingDirectory}) =>
                throw ProcessException(exe, args, 'no such file'),
      );
      addTearDown(manager.dispose);
      expect(await manager.ensureRunning(), isNull);
    });

    test('unexpected exit clears the endpoint and fires onExit', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final spawned = <Process>[];
      int? exitCode;
      final manager = await fakeManager(
        dir: dir,
        onExit: (code) => exitCode = code,
        spawnProcess:
            (exe, args, {required environment, required workingDirectory}) async {
          final proc = await Process.start('sleep', ['30']);
          spawned.add(proc);
          return proc;
        },
      );
      addTearDown(manager.dispose);

      expect(await manager.ensureRunning(), isNotNull);
      spawned.single.kill();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(manager.endpoint, isNull);
      expect(exitCode, isNotNull);

      // The next ensureRunning spawns a fresh process.
      expect(await manager.ensureRunning(), isNotNull);
      expect(spawned, hasLength(2));
    });

    test('stop kills the process without firing onExit', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final spawned = <Process>[];
      var exitFired = false;
      final manager = await fakeManager(
        dir: dir,
        onExit: (_) => exitFired = true,
        spawnProcess:
            (exe, args, {required environment, required workingDirectory}) async {
          final proc = await Process.start('sleep', ['30']);
          spawned.add(proc);
          return proc;
        },
      );
      addTearDown(manager.dispose);

      await manager.ensureRunning();
      await manager.stop();

      await spawned.single.exitCode.timeout(const Duration(seconds: 5));
      expect(exitFired, isFalse);
      expect(manager.endpoint, isNull);
    });

    test('stops retrying after repeated quick exits', () async {
      final dir = Directory.systemTemp.createTempSync('local_server_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      var spawns = 0;
      final manager = await fakeManager(
        dir: dir,
        spawnProcess:
            (exe, args, {required environment, required workingDirectory}) {
          spawns++;
          return Process.start('sh', ['-c', 'exit 1']);
        },
        healthCheck: (_) async => false,
      );
      addTearDown(manager.dispose);

      for (var i = 0; i < 5; i++) {
        expect(await manager.ensureRunning(), isNull);
      }
      expect(spawns, 3);
    });
  });
}
