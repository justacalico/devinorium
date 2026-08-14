import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('ThreadPage shows Running while sending', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [Message(role: 'user', content: 'hi')],
      ),
      sending: true,
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    ));
    await tester.pump();

    expect(find.text('Thread one'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
  });

  testWidgets('ThreadPage shows Done when last message is assistant', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(role: 'user', content: 'hi'),
          Message(role: 'assistant', content: 'hello'),
        ],
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    ));
    await tester.pump();

    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('ThreadPage shows Working when last message is user and not sending', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [Message(role: 'user', content: 'hi')],
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    ));
    await tester.pump();

    expect(find.text('Working'), findsOneWidget);
  });

  testWidgets('ThreadPage shows Needs approval when a permission request is pending', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [Message(role: 'user', content: 'hi')],
      ),
      sending: true,
      pendingPermissionRequest: PermissionRequest(
        requestId: 'r1',
        scope: 'exec',
        title: 'Run command',
        options: [
          PermissionOption(id: 'once', kind: 'once', label: 'Once'),
        ],
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const ThreadPage(),
      ),
    ));
    await tester.pump();

    expect(find.text('Needs approval'), findsOneWidget);
  });
}
