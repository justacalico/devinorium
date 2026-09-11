import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecordingApi extends ApiService {
  _RecordingApi() : super(client: _ThrowingClient());

  String? sentPrompt;
  List<String> sentReferencedThreadIds = const [];

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) => Future.value();

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
  }) {
    sentPrompt = prompt;
    sentReferencedThreadIds = referencedThreadIds;
    return Stream.fromIterable([
      SseEvent(
        'user_message',
        '{"id": 2, "role": "user", "content": "hello"}',
        id: '1',
      ),
      SseEvent(
        'done',
        '{"id": 3, "role": "assistant", "content": "ok"}',
        id: '2',
      ),
    ]);
  }
}

Thread _thread(String id, String title, {int projectId = 1}) => Thread(
  id: id,
  title: title,
  projectId: projectId,
  model: 'm1',
  permissionMode: 'normal',
  createdAt: '',
  updatedAt: '',
);

AppState _testState({_RecordingApi? api}) => AppState.test(
  api: api,
  user: User(
    id: 1,
    username: 'owner',
    role: 'user',
    totpEnabled: false,
    isOwner: true,
    providerId: 'devin-cli',
    providerCommand: 'devin',
  ),
  activeProjectId: 1,
  activeThreadId: 't1',
  activeThreadDetail: ThreadDetail(
    thread: _thread('t1', 'Current'),
    messages: const [],
  ),
);

Widget _threadApp(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const Scaffold(body: ThreadPage()),
  ),
);

void main() {
  testWidgets('thread references render as chips and dedupe by id', (
    tester,
  ) async {
    final state = _testState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    state.addThreadReference(const ThreadReference(id: 'a', title: 'Alpha'));
    state.addThreadReference(const ThreadReference(id: 'b', title: 'Beta'));
    state.addThreadReference(const ThreadReference(id: 'a', title: 'Alpha'));
    // Referencing the thread being composed is ignored.
    state.addThreadReference(
      const ThreadReference(id: 't1', title: 'Current'),
    );
    await tester.pump();

    expect(state.threadReferences, hasLength(2));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsNWidgets(2));
  });

  testWidgets('removing a thread reference drops the chip', (tester) async {
    final state = _testState();
    addTearDown(state.dispose);
    state.addThreadReference(const ThreadReference(id: 'a', title: 'Alpha'));
    state.addThreadReference(const ThreadReference(id: 'b', title: 'Beta'));

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    state.removeThreadReference(0);
    await tester.pump();

    expect(state.threadReferences.single.id, 'b');
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('send forwards referenced thread ids and clears them', (
    tester,
  ) async {
    final api = _RecordingApi();
    final state = _testState(api: api);
    addTearDown(state.dispose);
    state.addThreadReference(const ThreadReference(id: 'a', title: 'Alpha'));
    state.addThreadReference(const ThreadReference(id: 'b', title: 'Beta'));
    state.setComposerText('what did we decide');
    await tester.pump();

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    expect(api.sentPrompt, 'what did we decide');
    expect(api.sentReferencedThreadIds, ['a', 'b']);
    expect(state.threadReferences, isEmpty);
  });

  testWidgets('send works with only a thread reference', (tester) async {
    final api = _RecordingApi();
    final state = _testState(api: api);
    addTearDown(state.dispose);
    state.addThreadReference(const ThreadReference(id: 'a', title: 'Alpha'));

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    expect(api.sentReferencedThreadIds, ['a']);
    expect(api.sentPrompt, '');
  });

  testWidgets('sent message renders thread refs as chat chips', (
    tester,
  ) async {
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
      activeProjectId: 1,
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread('t1', 'Current'),
        messages: [
          Message(
            id: 1,
            role: 'user',
            content: 'see this thread',
            attachments: [
              Attachment(filename: 'Alpha', size: 0, isThreadRef: true),
            ],
          ),
        ],
        totalMessages: 1,
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  testWidgets('dragging a thread tile into the composer adds a chip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        _thread('t1', 'Current'),
        _thread('a', 'Other thread'),
      ],
      activeProjectId: 1,
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread('t1', 'Current'),
        messages: const [],
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 300, child: Sidebar()),
                Expanded(child: ThreadPage()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.text('Other thread');
    final target = find.byKey(const Key('composer_input'));
    expect(tile, findsOneWidget);
    expect(target, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(state.threadReferences.single.id, 'a');
    expect(state.threadReferences.single.title, 'Other thread');
  });

  testWidgets('dropping the active thread onto its composer is ignored', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        _thread('t1', 'Current'),
        _thread('a', 'Other thread'),
      ],
      activeProjectId: 1,
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread('t1', 'Current'),
        messages: const [],
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 300, child: Sidebar()),
                Expanded(child: ThreadPage()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 'Current' appears twice: once in the sidebar tile and once as the
    // thread page title. The tile is the one inside the sidebar.
    final tile = find
        .descendant(
          of: find.byType(Sidebar),
          matching: find.text('Current'),
        )
        .first;
    final target = find.byKey(const Key('composer_input'));

    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(state.threadReferences, isEmpty);
  });
}
