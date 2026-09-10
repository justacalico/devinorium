import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelPicker', () {
    final models = [
      ModelInfo(
        id: 'swe-1.7-max',
        label: 'SWE-1.7 Max',
        costTier: 'free',
        family: 'SWE-1.7',
      ),
      ModelInfo(
        id: 'glm-5-2',
        label: 'GLM-5-2',
        costTier: 'medium',
        family: 'GLM',
      ),
    ];

    Future<void> pumpAndOpen(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ModelPicker(
                value: 'swe-1.7-max',
                models: models,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ModelPicker));
      await tester.pumpAndSettle();
    }

    final searchField = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(EditableText),
    );

    testWidgets('does not focus the search field when opened', (tester) async {
      await pumpAndOpen(tester);

      expect(find.byType(Dialog), findsOneWidget);
      final field = tester.widget<EditableText>(searchField);
      expect(field.focusNode.hasFocus, isFalse);
    });

    testWidgets('focuses the search field when tapped', (tester) async {
      await pumpAndOpen(tester);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(searchField);
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('shows a gift icon on free model badges', (tester) async {
      await pumpAndOpen(tester);

      // One icon in the list row badge, one in the details pane badge.
      expect(find.byIcon(Icons.card_giftcard), findsNWidgets(2));
    });
  });
}
