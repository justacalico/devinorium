import 'package:devinorium_frontend/theme/semantic_colors.dart';
import 'package:devinorium_frontend/widgets/owner_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('OwnerBadge renders Owner label with warning colors', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: OwnerBadge()));

    expect(find.text('Owner'), findsOneWidget);

    final semantic = SemanticColors.fallback(Brightness.light);
    final container = tester.widget<Container>(
      find.ancestor(of: find.text('Owner'), matching: find.byType(Container)),
    );
    expect((container.decoration as BoxDecoration).color, semantic.warning);
    final text = tester.widget<Text>(find.text('Owner'));
    expect(text.style?.color, semantic.onWarning);
  });
}
