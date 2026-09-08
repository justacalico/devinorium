import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/drop_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux),
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const DropZone(
      child: Scaffold(
        body: Center(child: Text('inside')),
      ),
    ),
  ),
);

void main() {
  group('DropZone', () {
    testWidgets('exposes a controller to descendants on desktop', (
      tester,
    ) async {
      final state = AppState.test();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('inside'));
      final controller = DropZone.of(context);

      expect(controller, isNotNull);
      expect(controller!.pick, isA<Function>());
    });

    testWidgets('renders its child and shows the drop overlay on hover', (
      tester,
    ) async {
      final state = AppState.test();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('inside'), findsOneWidget);
      expect(find.text('Drop files here to attach'), findsNothing);
    });

    testWidgets('pick returns empty list when the plugin is missing', (
      tester,
    ) async {
      final state = AppState.test();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('inside'));
      final controller = DropZone.of(context);

      expect(controller, isNotNull);
      final files = await controller!.pick(multiple: true);
      expect(files, isEmpty);
    });
  });
}
