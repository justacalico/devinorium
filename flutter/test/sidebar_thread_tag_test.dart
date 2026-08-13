import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Sidebar shows thread tags in thread list', (tester) async {
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
      projects: [
        Project(id: 1, name: 'P', path: '/tmp/p', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 't1',
          title: 'Thread one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          tags: const ['completed'],
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 't1',
    );

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Sidebar(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Thread one'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
  });
}
