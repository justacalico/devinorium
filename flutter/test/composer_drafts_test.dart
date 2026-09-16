import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient implements BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// ApiService with just enough surface for bootstrap, openThread, send and
/// delete. Send streams are scripted per test through [sendHandler].
class _DraftApi extends ApiService {
  _DraftApi() : super(client: _FakeClient());

  final threads = <String, Thread>{'t1': _thread('t1'), 't2': _thread('t2')};
  var _nextId = 0;

  Stream<SseEvent> Function(String? clientMessageId)? sendHandler;
  final sentPrompts = <String>[];
  final deletedIds = <String>[];
  final failingThreads = <String>{};

  static Thread _thread(String id) => Thread(
    id: id,
    title: 'Thread $id',
    projectId: 1,
    model: '',
    permissionMode: 'normal',
    createdAt: '',
    updatedAt: '',
  );

  @override
  Future<User> me() => Future.value(
    User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      isOwner: true,
      providerId: 'devin-cli',
      providerCommand: 'devin',
    ),
  );

  @override
  Future<List<ProviderInfo>> listProviders() =>
      Future.value([ProviderInfo(id: 'devin-cli', name: 'Devin CLI')]);

  @override
  Future<List<ModelInfo>> listModels({String? provider}) =>
      Future.value(const []);

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) => Future.value(
    [Project(id: 1, name: 'p', path: '/tmp/p', createdAt: '', updatedAt: '')],
  );

  @override
  Future<List<ProjectGroup>> listProjectGroups({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value(threads.values.toList());

  @override
  Future<List<Thread>> listThreadsForProject(
    int projectId, {
    int? limit,
    int? offset,
  }) => Future.value(
    threads.values.where((t) => t.projectId == projectId).toList(),
  );

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<String>> getThreadRuns() => Future.value(const []);

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value(const {'status': 'idle'});

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) {
    if (failingThreads.contains(id)) {
      return Future.error(StateError('cannot open $id'));
    }
    return Future.value(
      ThreadDetail(thread: threads[id] ?? _thread(id), totalMessages: 0),
    );
  }

  @override
  Future<Map<String, dynamic>> getThreadProject(String id) =>
      Future.value({'project_id': 1});

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) => Future.value(const MessagePage());

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
  Future<Thread> createThread({
    required int projectId,
    String? title,
    int? threadGroupId,
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? branch,
    String? worktreePath,
    String? envMode,
  }) {
    final t = _thread('t-new-${_nextId++}');
    threads[t.id] = t;
    return Future.value(t);
  }

  @override
  Future<void> deleteThread(String id) {
    deletedIds.add(id);
    threads.remove(id);
    return Future.value();
  }

  @override
  Future<bool> checkHealth() => Future.value(true);

  @override
  Future<String?> serverVersion() => Future.value('0.1');

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
    List<int> machineIds = const [],
  }) {
    sentPrompts.add(prompt);
    final handler = sendHandler;
    if (handler != null) return handler(clientMessageId);
    return Stream.fromIterable([
      SseEvent(
        'user_message',
        '{"id": 2, "role": "user", "content": "", '
            '"client_message_id": "$clientMessageId"}',
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

/// Draft entries are namespaced by server id; AppState.test registers the
/// 'test' profile, so t1's draft lives under 'test:t1'.
Future<Map<String, dynamic>> _storedDrafts() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('devinorium_composer_drafts');
  if (raw == null || raw.isEmpty) return {};
  return Map<String, dynamic>.from(jsonDecode(raw) as Map);
}

/// Give the async SharedPreferences write a chance to land.
Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 20));

AppState _state(_DraftApi api) => AppState.test(
  api: api,
  projects: [
    Project(id: 1, name: 'p', path: '/tmp/p', createdAt: '', updatedAt: ''),
  ],
  activeProjectId: 1,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('typing stores a draft under the active thread', () async {
    final state = _state(_DraftApi());
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('first draft');
    await _flush();

    final drafts = await _storedDrafts();
    expect(drafts['test:t1'], 'first draft');
  });

  test('two threads keep independent drafts across switches', () async {
    final state = _state(_DraftApi());
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('draft for t1');

    await state.openThread('t2');
    expect(state.composerText, '');
    state.setComposerText('draft for t2');

    await state.openThread('t1');
    expect(state.composerText, 'draft for t1');

    await state.openThread('t2');
    expect(state.composerText, 'draft for t2');

    await _flush();
    final drafts = await _storedDrafts();
    expect(drafts['test:t1'], 'draft for t1');
    expect(drafts['test:t2'], 'draft for t2');
  });

  test('a draft typed into a brand new thread survives too', () async {
    final api = _DraftApi();
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('old thread draft');

    await state.createNewThread();
    final newId = state.activeThreadId!;
    expect(newId, isNot('t1'));
    state.setComposerText('new thread draft');

    await state.openThread('t1');
    expect(state.composerText, 'old thread draft');

    await state.openThread(newId);
    expect(state.composerText, 'new thread draft');
  });

  test('a persisted draft is restored on first open after a restart', () async {
    SharedPreferences.setMockInitialValues({
      'devinorium_composer_drafts': jsonEncode({'test:t1': 'saved draft'}),
    });
    final state = _state(_DraftApi());
    addTearDown(state.dispose);

    await state.bootstrap();
    await state.openThread('t1');

    expect(state.composerText, 'saved draft');
  });

  test('a successful send clears the draft from disk', () async {
    final api = _DraftApi();
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('send me');
    await _flush();
    expect((await _storedDrafts())['test:t1'], 'send me');

    await state.sendMessage();
    await _flush();

    expect(api.sentPrompts, ['send me']);
    expect(state.composerText, '');
    expect((await _storedDrafts()).containsKey('test:t1'), isFalse);
  });

  test('a failed send puts the draft back', () async {
    final api = _DraftApi()
      ..sendHandler = (_) => Stream.error(StateError('offline'));
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('retry me');
    await state.sendMessage();
    await _flush();

    expect(state.composerText, 'retry me');
    expect((await _storedDrafts())['test:t1'], 'retry me');
  });

  test('text typed for a failed open does not clobber another draft', () async {
    final api = _DraftApi()..failingThreads.add('t2');
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('t1 draft');

    // The open fails, leaving no active store; typing lands in the scratch
    // field and persists under t2, the thread it was meant for.
    await state.openThread('t2');
    expect(state.activeThreadId, 't2');
    state.setComposerText('t2 draft');

    // Reopening t1 must not hand t2's scratch text to t1's store.
    await state.openThread('t1');
    expect(state.composerText, 't1 draft');

    await _flush();
    final drafts = await _storedDrafts();
    expect(drafts['test:t1'], 't1 draft');
    expect(drafts['test:t2'], 't2 draft');
  });

  test('switching mid-send restores the text and does not wedge resend',
      () async {
    // A send stream that never emits keeps the turn in flight.
    final api = _DraftApi()
      ..sendHandler = (_) =>
          Stream<SseEvent>.fromFuture(Completer<SseEvent>().future);
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('still sending');
    await state.sendMessage();
    expect(api.sentPrompts, ['still sending']);

    // The switch cancels the unacked stream; the text must come back as a
    // draft rather than vanish.
    await state.openThread('t2');
    await _flush();
    expect((await _storedDrafts())['test:t1'], 'still sending');

    // resumeThread reuses the cached store; it must not be stuck on the
    // orphaned pending send.
    await state.resumeThread('t1');
    expect(state.composerText, 'still sending');

    api.sendHandler = null;
    await state.sendMessage();
    expect(api.sentPrompts, ['still sending', 'still sending']);
  });

  test('deleting a thread drops its draft', () async {
    final api = _DraftApi();
    final state = _state(api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setComposerText('gone soon');
    await _flush();
    expect((await _storedDrafts())['test:t1'], 'gone soon');

    await state.openThread('t2');
    await state.deleteThread('t1');
    await _flush();

    expect(api.deletedIds, ['t1']);
    expect((await _storedDrafts()).containsKey('test:t1'), isFalse);
  });

  testWidgets('the input field follows the per-thread draft', (tester) async {
    final state = _state(_DraftApi());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    // runAsync escapes the fake-async zone; openThread's SharedPreferences
    // draft reads resolve on the real event loop.
    await tester.runAsync(() => state.openThread('t1'));
    await tester.pump();

    final input = find.byKey(const Key('composer_input'));
    await tester.enterText(input, 'text for t1');
    await tester.pump();

    await tester.runAsync(() => state.openThread('t2'));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '');

    await tester.enterText(input, 'text for t2');
    await tester.pump();

    await tester.runAsync(() => state.openThread('t1'));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'text for t1');
  });
}
