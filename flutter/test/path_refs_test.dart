import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
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
  List<PathRef> sentContextPaths = const [];

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
    sentContextPaths = contextPaths;
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

Widget _threadApp(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const Scaffold(body: ThreadPage()),
  ),
);

void main() {
  testWidgets('path refs render as chips and dedupe by path', (tester) async {
    final state = _testState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    state.addPathRef('src/main.dart', isDir: false);
    state.addPathRef('docs', isDir: true);
    state.addPathRef('src/main.dart', isDir: false);
    await tester.pump();

    expect(state.pathRefs, hasLength(2));
    expect(find.text('src/main.dart'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
  });

  testWidgets('removing a path ref drops the chip', (tester) async {
    final state = _testState();
    addTearDown(state.dispose);
    state.addPathRef('src/main.dart', isDir: false);
    state.addPathRef('docs', isDir: true);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    state.removePathRef(0);
    await tester.pump();

    expect(state.pathRefs.single.path, 'docs');
    expect(find.text('src/main.dart'), findsNothing);
    expect(find.text('docs'), findsOneWidget);
  });

  testWidgets('send forwards context paths and clears them', (tester) async {
    final api = _RecordingApi();
    final state = _testState(api: api);
    addTearDown(state.dispose);
    state.addPathRef('src/main.dart', isDir: false);
    state.addPathRef('docs', isDir: true);
    state.setComposerText('check this');

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    expect(api.sentPrompt, 'check this');
    expect(
      api.sentContextPaths.map((r) => r.path),
      ['src/main.dart', 'docs'],
    );
    expect(state.pathRefs, isEmpty);
  });

  testWidgets('sent message renders path refs with file/folder icons', (
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
        thread: Thread(
          id: 't1',
          title: 'Test',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            id: 1,
            role: 'user',
            content: 'see these',
            attachments: [
              Attachment(
                filename: 'src/main.dart',
                size: 0,
                isPathRef: true,
                isDir: false,
              ),
              Attachment(
                filename: 'docs',
                size: 0,
                isPathRef: true,
                isDir: true,
              ),
            ],
          ),
        ],
        totalMessages: 1,
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    expect(find.text('src/main.dart'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
  });

  testWidgets('send works with refs and no text', (tester) async {
    final api = _RecordingApi();
    final state = _testState(api: api);
    addTearDown(state.dispose);
    state.addPathRef('docs', isDir: true);

    await tester.pumpWidget(_threadApp(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    expect(api.sentContextPaths.single.path, 'docs');
    expect(api.sentContextPaths.single.isDir, isTrue);
  });

  testWidgets('dragging a file row into the composer adds a path ref', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = _testState();
    addTearDown(state.dispose);
    state.setFilesEntries([
      DirEntry(name: 'main.dart', isDir: false, size: 10),
      DirEntry(name: 'docs', isDir: true, size: 0),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const Scaffold(
            body: Row(
              children: [
                SizedBox(width: 300, child: FilesPanel()),
                Expanded(child: ThreadPage()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.text('main.dart');
    final target = find.byKey(const Key('composer_input'));
    expect(row, findsOneWidget);
    expect(target, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(state.pathRefs.single.path, 'main.dart');
    expect(state.pathRefs.single.isDir, isFalse);
  });
}
