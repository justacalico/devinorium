import 'package:devinorium_frontend/terminal/terminal_session.dart';
import 'package:devinorium_frontend/terminal/terminal_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/ui.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalViewWidget', () {

    late TerminalSession session;
    late TerminalController controller;
    String? setClipboardText;
    Map<String, dynamic>? clipboardGetData;
    final outputs = <String>[];

    setUp(() {
      setClipboardText = null;
      clipboardGetData = null;
      outputs.clear();

      session = TerminalSession(id: 't1', isLocal: false);
      session.terminal.onOutput = outputs.add;
      controller = TerminalController();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<dynamic, dynamic>;
          setClipboardText = args['text'] as String;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return clipboardGetData;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      session.dispose();
    });

    Widget buildTerminal() {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: TerminalViewWidget(
              session: session,
              controller: controller,
            ),
          ),
        ),
      );
    }

    testWidgets('pastes clipboard text on Ctrl+Shift+V', (tester) async {
      clipboardGetData = {'text': 'pasted line'};
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(outputs, contains('pasted line'));
    });

    testWidgets('copies selected text on Ctrl+Shift+C', (tester) async {
      session.terminal.write('hello world');
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      final start = session.terminal.buffer.createAnchor(0, 0);
      final end = session.terminal.buffer.createAnchor(5, 0);
      controller.setSelection(start, end);

      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(setClipboardText, 'hello');
    });

    testWidgets('does not copy on Ctrl+C without shift', (tester) async {
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(setClipboardText, isNull);
      expect(outputs, equals(const ['\x03']));
    });

    testWidgets('enables delete detection on iOS', (tester) async {
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.deleteDetection, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('enables delete detection on Android', (tester) async {
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.deleteDetection, isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('disables delete detection on desktop', (tester) async {
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(view.deleteDetection, isFalse);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('sends backspace on iOS hardware keyboard', (tester) async {
      await tester.pumpWidget(buildTerminal());
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      expect(outputs, equals(const ['\x7f']));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
