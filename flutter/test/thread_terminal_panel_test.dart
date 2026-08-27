import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/terminal/terminal_session.dart';
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
    expect(find.byKey(const ValueKey('addTerminalTab')), findsOneWidget);
    expect(find.byKey(const ValueKey('addRemoteTerminal')), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('hides content when open is false', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            open: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No terminal sessions'), findsNothing);
    expect(find.text('Terminal'), findsNothing);
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

  testWidgets('keeps sessions per thread when active thread changes', (
    tester,
  ) async {
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String threadId,
      required bool local,
    }) async {
      callCount++;
      return TerminalSession(
        id: 's-$callCount-$threadId',
        isLocal: local,
      );
    }

    Widget build(String threadId) => MaterialApp(
      home: Scaffold(
        body: ThreadTerminalPanel(
          key: const ValueKey('panel'),
          api: ApiService(),
          threadId: threadId,
          sessionFactory: sessionFactory,
        ),
      ),
    );

    await tester.pumpWidget(build('t1'));
    await tester.pumpAndSettle();
    expect(find.text('No terminal sessions'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('Tab 1'), findsOneWidget);
    expect(find.text('s-1-t1'), findsOneWidget);

    await tester.pumpWidget(build('t2'));
    await tester.pumpAndSettle();
    expect(find.text('s-1-t1'), findsNothing);
    expect(find.text('No terminal sessions'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('Tab 1'), findsOneWidget);
    expect(find.text('s-2-t2'), findsOneWidget);

    await tester.pumpWidget(build('t1'));
    await tester.pumpAndSettle();
    expect(find.text('s-1-t1'), findsOneWidget);
    expect(find.text('s-2-t2'), findsNothing);

    await tester.pumpWidget(build('t2'));
    await tester.pumpAndSettle();
    expect(find.text('s-2-t2'), findsOneWidget);
  });

  testWidgets('switches and closes tabs like a browser', (tester) async {
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String threadId,
      required bool local,
    }) async {
      callCount++;
      return TerminalSession(
        id: 's-$callCount',
        isLocal: local,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            sessionFactory: sessionFactory,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No terminal sessions'), findsOneWidget);

    // Add an empty tab, then a terminal inside it.
    await tester.tap(find.byKey(const ValueKey('addTerminalTab')));
    await tester.pumpAndSettle();
    expect(find.text('Tab 1'), findsOneWidget);
    expect(find.text('No terminal sessions'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1'), findsOneWidget);

    // Add a second tab and a terminal there.
    await tester.tap(find.byKey(const ValueKey('addTerminalTab')));
    await tester.pumpAndSettle();
    expect(find.text('Tab 2'), findsOneWidget);
    expect(find.text('s-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-2'), findsOneWidget);

    // Switch back to the first tab.
    await tester.tap(find.text('Tab 1'));
    await tester.pumpAndSettle();
    expect(find.text('s-1'), findsOneWidget);
    expect(find.text('s-2'), findsNothing);

    // Switch to the second tab again.
    await tester.tap(find.text('Tab 2'));
    await tester.pumpAndSettle();
    expect(find.text('s-2'), findsOneWidget);

    // Close the second tab; the first one should be active.
    expect(find.byTooltip('Close tab'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Close tab').last);
    await tester.pumpAndSettle();
    expect(find.text('Tab 2'), findsNothing);
    expect(find.text('s-2'), findsNothing);
    expect(find.text('s-1'), findsOneWidget);

    // Add another terminal to the first tab.
    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1'), findsOneWidget);
    expect(find.text('s-3'), findsOneWidget);

    // Close the second terminal in the active tab.
    expect(find.byTooltip('Close terminal'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Close terminal').last);
    await tester.pumpAndSettle();
    expect(find.text('s-3'), findsNothing);
    expect(find.text('s-1'), findsOneWidget);
  });

  testWidgets('confirms before closing non-blank terminal or tab', (
    tester,
  ) async {
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String threadId,
      required bool local,
    }) async {
      callCount++;
      final session = TerminalSession(
        id: 's-$callCount',
        isLocal: local,
      );
      session.terminal.write('hello');
      return session;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadTerminalPanel(
            api: ApiService(),
            threadId: 't1',
            sessionFactory: sessionFactory,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Add a tab with a non-blank terminal.
    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1'), findsOneWidget);
    expect(find.text('Close terminal?'), findsNothing);

    // Closing the terminal shows a confirmation dialog.
    await tester.tap(find.byTooltip('Close terminal'));
    await tester.pumpAndSettle();
    expect(find.text('Close terminal?'), findsOneWidget);

    // Cancel keeps the terminal.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Close terminal?'), findsNothing);
    expect(find.text('s-1'), findsOneWidget);

    // Confirm closes the terminal.
    await tester.tap(find.byTooltip('Close terminal'));
    await tester.pumpAndSettle();
    expect(find.text('Close terminal?'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Close terminal?'), findsNothing);
    expect(find.text('s-1'), findsNothing);
    expect(find.text('No terminal sessions'), findsOneWidget);

    // Add another non-blank terminal to the same tab.
    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-2'), findsOneWidget);

    // Closing the tab with a non-blank terminal shows a confirmation dialog.
    await tester.tap(find.byTooltip('Close tab'));
    await tester.pumpAndSettle();
    expect(find.text('Close tab?'), findsOneWidget);

    // Cancel keeps the tab.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Close tab?'), findsNothing);
    expect(find.text('s-2'), findsOneWidget);

    // Confirm closes the tab.
    await tester.tap(find.byTooltip('Close tab'));
    await tester.pumpAndSettle();
    expect(find.text('Close tab?'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Close tab?'), findsNothing);
    expect(find.text('s-2'), findsNothing);
    expect(find.text('No terminal sessions'), findsOneWidget);
  });
}
