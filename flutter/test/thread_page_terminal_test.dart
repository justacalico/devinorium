import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/terminal/terminal_panel.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

void main() {
  testWidgets('toggling the terminal icon opens and closes the bottom panel', (
    tester,
  ) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('No terminal sessions'), findsNothing);
    // The panel is always mounted; the store controls visibility.
    expect(find.byType(TerminalPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.terminal));
    await tester.pumpAndSettle();

    expect(state.terminalStore.open, isTrue);
    expect(find.text('No terminal sessions'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();

    expect(state.terminalStore.open, isFalse);
    expect(find.text('No terminal sessions'), findsNothing);
  });

  testWidgets('terminal toggle works without an active thread', (tester) async {
    final state = AppState.test();
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.terminal));
    await tester.pumpAndSettle();

    expect(state.terminalStore.open, isTrue);
    expect(find.text('Terminal'), findsOneWidget);
  });
}
