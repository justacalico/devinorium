import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/l10n/global_l10n.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/state/thread_store.dart';
import 'package:devinorium_frontend/views/drop_zone.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeApi extends ApiService {
  _FakeApi() : super(client: _ThrowingClient());

  ThreadContextUsage usage = const ThreadContextUsage(
    usedTokens: 1000,
    contextLimit: 200000,
    outputLimit: 4000,
    hasSession: true,
  );
  int getContextCalls = 0;
  int resetCalls = 0;
  int sendCalls = 0;
  int? lastMaxOutputTokens;
  var setMaxOutputTokensCalled = false;

  @override
  Future<ThreadContextUsage> getThreadContext(String id) {
    getContextCalls++;
    return Future.value(usage);
  }

  @override
  Future<void> resetThreadContext(String id) {
    resetCalls++;
    return Future.value();
  }

  @override
  Future<void> setThreadMaxOutputTokens(String id, int? tokens) {
    setMaxOutputTokensCalled = true;
    lastMaxOutputTokens = tokens;
    return Future.value();
  }

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) => Future.value(
    ThreadDetail(
      thread: Thread(
        id: id,
        title: 'Test',
        projectId: 1,
        model: 'm1',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      ),
      messages: const [],
      totalMessages: 0,
    ),
  );

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async => const MessagePage(messages: [], total: 0);

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

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
    sendCalls++;
    return Stream.fromIterable([
      SseEvent(
        'user_message',
        '{"id": 2, "role": "user", "content": "hi"}',
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

ThreadStore _store(_FakeApi api, {String composerText = ''}) {
  final store = ThreadStore(
    api: api,
    threadId: 't1',
    projectId: 1,
    composerText: composerText,
  );
  // sendMessage treats a null listener as a deactivated store and bails.
  store.onStateChanged = () {};
  return store;
}

void main() {
  group('ThreadContextUsage', () {
    test('parses the context endpoint response', () {
      final u = ThreadContextUsage.fromJson(const {
        'used_tokens': 1500,
        'context_limit': 200000,
        'output_limit': 8192,
        'max_output_tokens': 4096,
        'has_session': true,
      });
      expect(u.usedTokens, 1500);
      expect(u.contextLimit, 200000);
      expect(u.outputLimit, 8192);
      expect(u.maxOutputTokens, 4096);
      expect(u.hasSession, isTrue);
    });

    test('output reserve prefers the thread override', () {
      const u = ThreadContextUsage(
        usedTokens: 0,
        contextLimit: 100,
        outputLimit: 8000,
        maxOutputTokens: 2000,
      );
      expect(u.outputReserve, 2000);
      const noOverride = ThreadContextUsage(
        usedTokens: 0,
        contextLimit: 100,
        outputLimit: 8000,
      );
      expect(noOverride.outputReserve, 8000);
      const unknown = ThreadContextUsage(
        usedTokens: 0,
        contextLimit: 100,
        outputLimit: 0,
      );
      expect(unknown.outputReserve, 8192);
    });

    test('exceedsLimit accounts for draft and reserve', () {
      const u = ThreadContextUsage(
        usedTokens: 900,
        contextLimit: 2000,
        outputLimit: 1000,
      );
      expect(u.exceedsLimit(50), isFalse);
      expect(u.exceedsLimit(200), isTrue);
    });
  });

  group('ThreadStore context', () {
    test('load fetches the usage estimate', () async {
      final api = _FakeApi();
      final store = _store(api);
      await store.load();
      await pumpEventQueue();
      expect(api.getContextCalls, greaterThan(0));
      expect(store.contextUsage?.usedTokens, 1000);
    });

    test('send proceeds when the estimate fits', () async {
      final api = _FakeApi();
      final store = _store(api, composerText: 'hi');
      await store.sendMessage();
      await pumpEventQueue();
      expect(api.sendCalls, 1);
      expect(store.globalError, isEmpty);
    });

    test('send is blocked when the draft overflows the window', () async {
      final api = _FakeApi()
        ..usage = const ThreadContextUsage(
          usedTokens: 197000,
          contextLimit: 200000,
          outputLimit: 4000,
          hasSession: true,
        );
      final store = _store(api, composerText: 'hi');
      await store.refreshContextUsage();
      expect(store.sendExceedsContext, isTrue);
      await store.sendMessage();
      await pumpEventQueue();
      expect(api.sendCalls, 0);
      expect(store.globalError, appL10n.contextExceeded);
      expect(store.composerText, 'hi');
    });

    test('no limit means no gating', () async {
      final api = _FakeApi()
        ..usage = const ThreadContextUsage(
          usedTokens: 0,
          contextLimit: 0,
          outputLimit: 0,
        );
      final store = _store(api, composerText: 'hi');
      await store.refreshContextUsage();
      expect(store.sendExceedsContext, isFalse);
      await store.sendMessage();
      await pumpEventQueue();
      expect(api.sendCalls, 1);
    });

    test('resetContext drops the session estimate', () async {
      final api = _FakeApi();
      final store = _store(api);
      await store.load();
      await pumpEventQueue();
      api.usage = const ThreadContextUsage(
        usedTokens: 0,
        contextLimit: 200000,
        outputLimit: 4000,
      );
      await store.resetContext();
      expect(api.resetCalls, 1);
      await pumpEventQueue();
      expect(store.contextUsage?.usedTokens, 0);
      expect(store.contextUsage?.hasSession, isFalse);
    });

    test('setThreadMaxOutputTokens patches the thread', () async {
      final api = _FakeApi();
      final store = _store(api);
      await store.setThreadMaxOutputTokens(4096);
      expect(api.setMaxOutputTokensCalled, isTrue);
      expect(api.lastMaxOutputTokens, 4096);
      await store.setThreadMaxOutputTokens(null);
      expect(api.lastMaxOutputTokens, isNull);
    });
  });

  group('composer meter', () {
    AppState buildState(
      _FakeApi api, {
      ThreadContextUsage? usage,
      String composerText = '',
      int? maxOutputTokens,
    }) => AppState.test(
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
          maxOutputTokens: maxOutputTokens,
        ),
        messages: const [],
      ),
      threadContextUsage: usage,
      composerText: composerText,
    );

    Widget app(AppState state) => MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const DropZone(child: ThreadPage()),
      ),
    );

    testWidgets('shows usage under the composer', (tester) async {
      final api = _FakeApi();
      final state = buildState(
        api,
        usage: const ThreadContextUsage(
          usedTokens: 50000,
          contextLimit: 200000,
          outputLimit: 4000,
          hasSession: true,
        ),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      final meter = tester.widget<Text>(
        find.byKey(const Key('context_meter_text')),
      );
      expect(meter.data, contains('200K'));
      expect(find.byKey(const Key('context_warning_text')), findsNothing);
      expect(find.byKey(const Key('context_exceeded_text')), findsNothing);
    });

    testWidgets('warns near the limit and blocks the send', (tester) async {
      final api = _FakeApi();
      final state = buildState(
        api,
        usage: const ThreadContextUsage(
          usedTokens: 197000,
          contextLimit: 200000,
          outputLimit: 3900,
          hasSession: true,
        ),
        composerText: 'hi',
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('context_warning_text')), findsNothing);
      expect(find.byKey(const Key('context_exceeded_text')), findsOneWidget);
      expect(find.byKey(const Key('context_reset_button')), findsOneWidget);

      // The send button must not dispatch while over the limit.
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(api.sendCalls, 0);
      expect(state.composerText, 'hi');
    });

    testWidgets('shows the warning state between 80% and 100%', (tester) async {
      final api = _FakeApi();
      final state = buildState(
        api,
        usage: const ThreadContextUsage(
          usedTokens: 165000,
          contextLimit: 200000,
          outputLimit: 4000,
          hasSession: true,
        ),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('context_warning_text')), findsOneWidget);
      expect(find.byKey(const Key('context_exceeded_text')), findsNothing);
      expect(find.byKey(const Key('context_reset_icon')), findsOneWidget);
    });

    testWidgets('hides the meter when the model has no limit', (tester) async {
      final api = _FakeApi();
      final state = buildState(
        api,
        usage: const ThreadContextUsage(
          usedTokens: 0,
          contextLimit: 0,
          outputLimit: 0,
        ),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('context_meter_text')), findsNothing);
    });

    testWidgets('reset button calls the api', (tester) async {
      final api = _FakeApi();
      final state = buildState(
        api,
        usage: const ThreadContextUsage(
          usedTokens: 50000,
          contextLimit: 200000,
          outputLimit: 4000,
          hasSession: true,
        ),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('context_reset_icon')));
      await tester.pumpAndSettle();
      expect(api.resetCalls, 1);
    });
  });
}
