import 'package:devinorium_frontend/widgets/owner_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('OwnerBadge renders yellow Owner label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OwnerBadge()),
    );

    expect(find.text('Owner'), findsOneWidget);

    final container = tester.widget<Container>(
      find.ancestor(of: find.text('Owner'), matching: find.byType(Container)),
    );
    expect(
      (container.decoration as BoxDecoration).color,
      const Color(0xFFFFC107),
    );
  });
}
