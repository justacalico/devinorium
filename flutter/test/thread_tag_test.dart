import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ThreadTag renders label with leading dot', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ThreadTag('working')));
    expect(find.text('Working'), findsOneWidget);
    expect(find.byType(Container), findsWidgets);
  });

  testWidgets('ThreadTag capitalizes label', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ThreadTag('needs approval')));
    expect(find.text('Needs approval'), findsOneWidget);
  });

  testWidgets('ThreadTag renders running and done', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ThreadTag('running')));
    expect(find.text('Running'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: ThreadTag('done')));
    expect(find.text('Done'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: ThreadTag('failed')));
    expect(find.text('Failed'), findsOneWidget);
  });
}
