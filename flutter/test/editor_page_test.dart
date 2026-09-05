import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/editor/agent_panel.dart';
import 'package:devinorium_frontend/views/editor/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: EditorPage()),
    );

void main() {
  group('EditorPage agent panel', () {
    testWidgets('is closed by default on narrow layouts', (tester) async {
      final state = AppState.test();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();

      expect(find.byType(AgentPanel), findsNothing);
      expect(find.byIcon(Icons.chat_outlined), findsOneWidget);
    });

    testWidgets('is open by default on wide layouts', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = AppState.test();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();

      expect(find.byType(AgentPanel), findsOneWidget);
    });

    testWidgets('floating toggle opens the panel on narrow layouts',
        (tester) async {
      final state = AppState.test();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.chat_outlined));
      await tester.pump();

      expect(state.agentPanelUserSet, isTrue);
      expect(find.byType(AgentPanel), findsOneWidget);
    });

    testWidgets('follows the layout until the user toggles it',
        (tester) async {
      final state = AppState.test();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();
      expect(find.byType(AgentPanel), findsNothing);

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();

      expect(find.byType(AgentPanel), findsOneWidget);
    });

    testWidgets('explicit choice sticks across layout changes',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = AppState.test();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();
      expect(find.byType(AgentPanel), findsOneWidget);

      state.setAgentPanelOpen(false);
      await tester.pump();

      tester.view.physicalSize = const Size(800, 600);
      await tester.pump();

      expect(find.byType(AgentPanel), findsNothing);
      expect(find.byIcon(Icons.chat_outlined), findsOneWidget);
    });
  });
}
