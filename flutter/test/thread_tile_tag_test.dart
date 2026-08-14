import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ThreadTag fits inside a ListTile subtitle', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ListTile(
          title: Text('Hello'),
          subtitle: ThreadTag('done'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Done'), findsOneWidget);
  });
}
