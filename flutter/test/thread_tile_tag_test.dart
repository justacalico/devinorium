import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ThreadTag fits inside a ListTile subtitle', (tester) async {
    final thread = Thread(
      id: 't1',
      title: 'Hello',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      tags: const ['completed'],
      createdAt: '',
      updatedAt: '',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListTile(
          title: Text(thread.title),
          subtitle: ThreadTag(thread.tags.first),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Completed'), findsOneWidget);
  });
}
