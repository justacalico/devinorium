import 'dart:typed_data';

import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

AppState _testState() => AppState.test(
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
      title: 'Test',
      projectId: 1,
      model: 'm1',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
    ),
    messages: const [],
  ),
);

void main() {
  group('composer attachment chips', () {
    testWidgets('appear immediately when attachments are added', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('photo.png'), findsNothing);

      state.addAttachments([
        (filename: 'photo.png', mime: 'image/png', bytes: Uint8List(0)),
      ]);
      await tester.pump();

      expect(find.text('photo.png'), findsOneWidget);
    });

    testWidgets('disappear immediately when attachments are cleared', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      state.addAttachments([
        (filename: 'photo.png', mime: 'image/png', bytes: Uint8List(0)),
      ]);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('photo.png'), findsOneWidget);

      state.clearAttachments();
      await tester.pump();

      expect(find.text('photo.png'), findsNothing);
    });
  });
}
