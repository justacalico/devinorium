import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/model_picker.dart';
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

AppState _testState() => AppState.test(
  user: User(
    id: 1,
    username: 'owner',
    role: 'user',
    totpEnabled: false,
    isOwner: true,
    providerId: 'devin-cli',
    providerCommand: 'devin',
  ),
  models: [
    ModelInfo(
      id: 'swe-1.7-max',
      label: 'SWE-1.7 Max',
      costTier: 'free',
      family: 'SWE-1.7',
    ),
  ],
  activeThreadId: 't1',
  selectedModel: 'swe-1.7-max',
  selectedPermission: 'bypass',
  activeThreadDetail: ThreadDetail(
    thread: Thread(
      id: 't1',
      title: 'Test',
      projectId: 1,
      model: 'swe-1.7-max',
      permissionMode: 'bypass',
      createdAt: '',
      updatedAt: '',
    ),
    messages: const [],
  ),
);

void main() {
  group('composer mobile layout', () {
    testWidgets(
      'uses compact labels and a horizontal scroll on narrow screens',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;

        final state = _testState();

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Max'), findsOneWidget);
        expect(find.text('SWE-1.7 Max'), findsNothing);
        expect(find.text('Auto'), findsOneWidget);
        expect(find.text('Auto-run'), findsNothing);
        expect(find.text('Code'), findsOneWidget);
        final dropdowns = find.byKey(const Key('composer_dropdowns'));
        expect(
          find.descendant(
            of: dropdowns,
            matching: find.byType(SingleChildScrollView),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dropdowns, matching: find.byType(Wrap)),
          findsNothing,
        );
      },
    );

    testWidgets('keeps full labels and a wrap on wide screens', (tester) async {
      final state = _testState();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('SWE-1.7 Max'), findsOneWidget);
      expect(find.text('Auto-run'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
      final dropdowns = find.byKey(const Key('composer_dropdowns'));
      expect(
        find.descendant(of: dropdowns, matching: find.byType(Wrap)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dropdowns,
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
    });
  });

  group('ModelPicker compact', () {
    testWidgets('uses a short label when compact is true', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ModelPicker(
                value: 'swe-1.7-max',
                compact: true,
                models: [
                  ModelInfo(
                    id: 'swe-1.7-max',
                    label: 'SWE-1.7 Max',
                    costTier: 'free',
                    family: 'SWE-1.7',
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Max'), findsOneWidget);
      expect(find.text('SWE-1.7 Max'), findsNothing);
    });

    testWidgets('strips the family and any leading separator', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ModelPicker(
                value: 'glm-5-2',
                compact: true,
                models: [
                  ModelInfo(
                    id: 'glm-5-2',
                    label: 'GLM-5-2',
                    costTier: 'free',
                    family: 'GLM',
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('5-2'), findsOneWidget);
      expect(find.text('-5-2'), findsNothing);
      expect(find.text('GLM-5-2'), findsNothing);
    });

    testWidgets('uses the full label when compact is false', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ModelPicker(
                value: 'swe-1.7-max',
                models: [
                  ModelInfo(
                    id: 'swe-1.7-max',
                    label: 'SWE-1.7 Max',
                    costTier: 'free',
                    family: 'SWE-1.7',
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SWE-1.7 Max'), findsOneWidget);
    });
  });
}
