import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/terminal/thread_terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows empty state and header controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No terminal sessions'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byIcon(Icons.cloud), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('tapping hide icon invokes onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });

  testWidgets('dragging the resize handle reports a new height', (
    tester,
  ) async {
    double? reportedHeight;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            initialHeight: 280,
            onHeightChanged: (height) => reportedHeight = height,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dragHandle = find.byKey(const ValueKey('terminalDragHandle'));
    expect(dragHandle, findsOneWidget);

    await tester.drag(dragHandle, const Offset(0, -50));
    await tester.pumpAndSettle();

    expect(reportedHeight, isNotNull);
    expect(reportedHeight, greaterThan(280));
  });
}
