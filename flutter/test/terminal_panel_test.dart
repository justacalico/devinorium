import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/terminal/terminal_panel.dart';
import 'package:devinorium_frontend/terminal/terminal_session.dart';
import 'package:devinorium_frontend/terminal/terminal_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TerminalStore _openStore({TerminalSessionFactory? sessionFactory}) =>
    TerminalStore(api: () => ApiService(), sessionFactory: sessionFactory)
      ..setOpen(true);

Widget _panel(TerminalStore store) => MaterialApp(
  home: Scaffold(body: TerminalPanel(store: store)),
);

void main() {
  testWidgets('shows empty state and header controls', (tester) async {
    final store = _openStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    expect(find.text('No terminal sessions'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byKey(const ValueKey('addTerminalTab')), findsOneWidget);
    expect(find.byKey(const ValueKey('addRemoteTerminal')), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('renders nothing when the store is closed', (tester) async {
    final store = TerminalStore(api: () => ApiService());
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    expect(find.text('No terminal sessions'), findsNothing);
    expect(find.text('Terminal'), findsNothing);
  });

  testWidgets('tapping hide icon closes the store', (tester) async {
    final store = _openStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();

    expect(store.open, isFalse);
    expect(find.text('Terminal'), findsNothing);
  });

  testWidgets('dragging the resize handle updates the store height', (
    tester,
  ) async {
    final store = _openStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    final dragHandle = find.byKey(const ValueKey('terminalDragHandle'));
    expect(dragHandle, findsOneWidget);

    await tester.drag(dragHandle, const Offset(0, -50));
    await tester.pumpAndSettle();

    expect(store.height, greaterThan(TerminalStore.defaultHeight));
  });

  testWidgets('sessions survive the panel being unmounted and remounted', (
    tester,
  ) async {
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String? threadId,
      required bool local,
    }) async {
      callCount++;
      return TerminalSession(id: 's-$callCount', isLocal: local);
    }

    final store = _openStore(sessionFactory: sessionFactory);
    addTearDown(store.dispose);

    // Simulate the agents view hosting the panel.
    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1'), findsOneWidget);

    // Simulate switching to the editor view: a fresh panel instance in a new
    // tree, backed by the same global store.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Editor')),
          body: TerminalPanel(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('s-1'), findsOneWidget);
    expect(store.tabs.single.sessions.single.id, 's-1');
  });

  testWidgets('sessions are global and survive active thread changes', (
    tester,
  ) async {
    var currentThread = 't1';
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String? threadId,
      required bool local,
    }) async {
      callCount++;
      return TerminalSession(id: 's-$callCount-$threadId', isLocal: local);
    }

    final store = TerminalStore(
      api: () => ApiService(),
      activeThreadId: () => currentThread,
      sessionFactory: sessionFactory,
    )..setOpen(true);
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1-t1'), findsOneWidget);

    // Switching threads must not hide or replace existing sessions.
    currentThread = 't2';
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('s-1-t1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();
    expect(find.text('s-1-t1'), findsOneWidget);
    expect(find.text('s-2-t2'), findsOneWidget);
  });

  testWidgets('switches and closes tabs like a browser', (tester) async {
    var callCount = 0;
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String? threadId,
      required bool local,
    }) async {
      callCount++;
      return TerminalSession(id: 's-$callCount', isLocal: local);
    }

    final store = _openStore(sessionFactory: sessionFactory);
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
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
      required String? threadId,
      required bool local,
    }) async {
      callCount++;
      final session = TerminalSession(id: 's-$callCount', isLocal: local);
      session.terminal.write('hello');
      return session;
    }

    final store = _openStore(sessionFactory: sessionFactory);
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
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

  testWidgets('session start failure shows a snackbar', (tester) async {
    Future<TerminalSession> sessionFactory({
      required ApiService api,
      required String? threadId,
      required bool local,
    }) async {
      throw StateError('boom');
    }

    final store = _openStore(sessionFactory: sessionFactory);
    addTearDown(store.dispose);

    await tester.pumpWidget(_panel(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('addRemoteTerminal')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(store.busy, isFalse);
  });
}
