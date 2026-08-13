import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('ThreadPage shows tags in app bar', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          tags: const ['working'],
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Thread one'), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
  });
}
