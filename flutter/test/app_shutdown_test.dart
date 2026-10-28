import 'dart:async';

import 'package:devinorium_frontend/services/local_server_types.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingLocalManager implements LocalServerController {
  int stopCalls = 0;
  int disposeCalls = 0;
  Completer<void>? stopGate;

  @override
  void Function(int exitCode)? onExit;

  @override
  bool get isSupported => true;

  @override
  bool get hasBinary => false;

  @override
  LocalServerEndpoint? get endpoint => null;

  @override
  Future<LocalServerEndpoint?> ensureRunning() async => null;

  @override
  Future<void> stop() async {
    stopCalls++;
    await stopGate?.future;
  }

  @override
  void dispose() {
    disposeCalls++;
    // Mirrors LocalServerManager.dispose(), which fires an unawaited stop.
    unawaited(stop());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('shutdown disposes the state and stops the bundled server', () async {
    final manager = _RecordingLocalManager();
    final state = AppState.test(localServerManager: manager);

    await state.shutdown();

    expect(manager.disposeCalls, 1);
    // Once from dispose's unawaited stop, once awaited by shutdown itself.
    expect(manager.stopCalls, 2);
  });

  test('concurrent shutdown calls share a single pass', () async {
    final manager = _RecordingLocalManager()
      ..stopGate = Completer<void>();
    final state = AppState.test(localServerManager: manager);

    final a = state.shutdown(
      serverStopTimeout: const Duration(milliseconds: 50),
    );
    final b = state.shutdown();
    await Future.wait([a, b]);

    // One dispose pass ran; the manager saw its own two stop() calls from
    // that single pass, not four.
    expect(manager.disposeCalls, 1);
    expect(manager.stopCalls, 2);
  });

  test('a stuck server stop does not block shutdown', () async {
    final manager = _RecordingLocalManager()..stopGate = Completer<void>();
    final state = AppState.test(localServerManager: manager);

    await state.shutdown(serverStopTimeout: const Duration(milliseconds: 50));

    expect(manager.stopCalls, 2);
  });

  test('shutdown persists composer drafts before exiting', () async {
    final manager = _RecordingLocalManager();
    final state = AppState.test(
      activeThreadId: 't1',
      localServerManager: manager,
    )..setComposerText('unfinished reply');

    await state.shutdown();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('devinorium_composer_drafts');
    expect(raw, isNotNull);
    expect(raw, contains('unfinished reply'));
  });
}
