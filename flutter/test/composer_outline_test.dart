import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

AppState _testState({
  ComposerMode mode = ComposerMode.code,
  String permission = 'normal',
}) => AppState.test(
  activeThreadId: 't1',
  composerMode: mode,
  selectedPermission: permission,
  activeThreadDetail: ThreadDetail(
    thread: Thread(
      id: 't1',
      title: 'Test',
      projectId: 1,
      model: 'm1',
      permissionMode: permission,
      createdAt: '',
      updatedAt: '',
    ),
    messages: const [],
  ),
);

Widget _buildWithState(AppState state) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      error: Colors.red,
    ),
  ),
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

BoxDecoration _findOutline(WidgetTester tester) {
  final outline = tester.widget<Container>(
    find.byKey(const Key('composer_outline')),
  );
  return outline.decoration as BoxDecoration;
}

Material _findCardMaterial(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) => w is Material && w.shape is RoundedRectangleBorder,
  );
  expect(finder, findsOneWidget);
  return tester.widget<Material>(finder);
}

double _radius(Material material) {
  final shape = material.shape as RoundedRectangleBorder;
  return (shape.borderRadius as BorderRadius).topLeft.x;
}

void main() {
  group('composer prompt outline', () {
    testWidgets('code + auto-run shows a solid red outline', (tester) async {
      final state = _testState(mode: ComposerMode.code, permission: 'bypass');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.color, Colors.red);
      expect(decoration.gradient, isNull);
    });

    testWidgets('ask + auto-run shows a gradient from green to red', (
      tester,
    ) async {
      final state = _testState(mode: ComposerMode.ask, permission: 'bypass');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      final gradient = decoration.gradient as LinearGradient;
      expect(gradient.colors, [const Color(0xFF4CAF50), Colors.red]);
    });

    testWidgets('plan + auto-run shows a gradient from amber to red', (
      tester,
    ) async {
      final state = _testState(mode: ComposerMode.plan, permission: 'bypass');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      final gradient = decoration.gradient as LinearGradient;
      expect(gradient.colors, [const Color(0xFFFFC107), Colors.red]);
    });

    testWidgets('ask + normal shows a solid green outline', (tester) async {
      final state = _testState(mode: ComposerMode.ask, permission: 'normal');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.color, const Color(0xFF4CAF50));
      expect(decoration.gradient, isNull);
    });

    testWidgets('plan + normal shows a solid amber outline', (tester) async {
      final state = _testState(mode: ComposerMode.plan, permission: 'normal');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.color, const Color(0xFFFFC107));
      expect(decoration.gradient, isNull);
    });

    testWidgets('ask + smart confirm shows a solid green outline', (
      tester,
    ) async {
      final state = _testState(mode: ComposerMode.ask, permission: 'smart');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.color, const Color(0xFF4CAF50));
      expect(decoration.gradient, isNull);
    });

    testWidgets('plan + confirm edits shows a solid amber outline', (
      tester,
    ) async {
      final state = _testState(
        mode: ComposerMode.plan,
        permission: 'accept-edits',
      );
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.color, const Color(0xFFFFC107));
      expect(decoration.gradient, isNull);
    });

    testWidgets('code + normal has no outline', (tester) async {
      final state = _testState(mode: ComposerMode.code, permission: 'normal');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('composer_outline')), findsNothing);

      final material = _findCardMaterial(tester);
      expect(material.elevation, 1.0);
      expect(material.clipBehavior, Clip.antiAlias);
      expect(_radius(material), 28.0);
    });

    testWidgets('ask + bypass uses inner radius and zero elevation', (
      tester,
    ) async {
      final state = _testState(mode: ComposerMode.ask, permission: 'bypass');
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final decoration = _findOutline(tester);
      expect(decoration.gradient, isNotNull);

      final material = _findCardMaterial(tester);
      expect(material.elevation, 0.0);
      expect(material.clipBehavior, Clip.antiAlias);
      expect(_radius(material), 26.0);
    });
  });
}
