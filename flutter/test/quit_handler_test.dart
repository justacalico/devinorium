import 'dart:async';

import 'package:devinorium_frontend/services/quit_handler_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channelCalls = <MethodCall>[];

  setUp(() {
    channelCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call);
      return true;
    });
  });

  tearDown(() async {
    for (final listener in windowManager.listeners) {
      windowManager.removeListener(listener);
    }
    await windowManager.setPreventClose(false);
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<WindowListener> install(
    Future<void> Function() shutdown, {
    required void Function(int exitCode) exitProcess,
    Duration cleanupTimeout = const Duration(seconds: 5),
  }) async {
    await installQuitHandler(
      shutdown,
      exitProcess: exitProcess,
      cleanupTimeout: cleanupTimeout,
    );
    expect(windowManager.hasListeners, isTrue);
    return windowManager.listeners.last;
  }

  test('enables prevent-close so closes route through Dart', () async {
    await install(() async {}, exitProcess: (_) {});
    expect(
      channelCalls.where((c) => c.method == 'setPreventClose'),
      isNotEmpty,
    );
  });

  test('close runs shutdown once then exits with code 0', () async {
    var shutdownCalls = 0;
    final exits = <int>[];
    final listener = await install(
      () async => shutdownCalls++,
      exitProcess: exits.add,
    );

    listener.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(shutdownCalls, 1);
    expect(exits, [0]);
  });

  test('a second close while cleanup runs does not re-run shutdown', () async {
    final gate = Completer<void>();
    var shutdownCalls = 0;
    final exits = <int>[];
    final listener = await install(() {
      shutdownCalls++;
      return gate.future;
    }, exitProcess: exits.add);

    listener.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    listener.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    expect(shutdownCalls, 1);
    expect(exits, isEmpty);

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(exits, [0]);
  });

  test('a hanging shutdown still exits after the cleanup timeout', () async {
    final exits = <int>[];
    final listener = await install(
      () => Completer<void>().future,
      exitProcess: exits.add,
      cleanupTimeout: const Duration(milliseconds: 50),
    );

    listener.onWindowClose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(exits, [0]);
  });

  test('a throwing shutdown still exits with code 0', () async {
    final exits = <int>[];
    final listener = await install(
      () async => throw StateError('boom'),
      exitProcess: exits.add,
    );

    listener.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(exits, [0]);
  });
}
