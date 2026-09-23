import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
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

  ThreadContextUsage usage = const ThreadContextUsage(hasSession: true);
  int getContextCalls = 0;
  int resetCalls = 0;
  int sendCalls = 0;

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
        'has_session': true,
        'usage': {
          'records': 3,
          'input_tokens': 12000,
          'output_tokens': 450,
          'thought_tokens': 800,
          'cached_read_tokens': 2000,
          'cached_write_tokens': 0,
          'total_tokens': 15250,
          'costs': [
            {'currency': 'USD', 'amount': 0.42},
          ],
        },
      });
      expect(u.hasSession, isTrue);
      expect(u.usage.records, 3);
      expect(u.usage.inputTokens, 12000);
      expect(u.usage.outputTokens, 450);
      expect(u.usage.thoughtTokens, 800);
      expect(u.usage.cachedReadTokens, 2000);
      expect(u.usage.totalTokens, 15250);
      expect(u.usage.costs, [const UsageCost(currency: 'USD', amount: 0.42)]);
    });

    test('defaults usage to zero totals when absent', () {
      final u = ThreadContextUsage.fromJson(const {});
      expect(u.usage, emptyUsageTotals);
    });

    test('equality includes the usage totals', () {
      const base = ThreadContextUsage();
      const withUsage = ThreadContextUsage(
        usage: UsageTotals(
          records: 1,
          inputTokens: 5,
          outputTokens: 2,
          thoughtTokens: 0,
          cachedReadTokens: 0,
          cachedWriteTokens: 0,
          totalTokens: 7,
          costs: [],
        ),
      );
      expect(base == withUsage, isFalse);
      expect(withUsage == withUsage, isTrue);
    });
  });

  group('ThreadStore context', () {
    test('load fetches the thread usage', () async {
      final api = _FakeApi();
      final store = _store(api);
      await store.load();
      await pumpEventQueue();
      expect(api.getContextCalls, greaterThan(0));
      expect(store.contextUsage?.hasSession, isTrue);
    });

    test('send proceeds regardless of recorded usage', () async {
      final api = _FakeApi()
        ..usage = const ThreadContextUsage(
          hasSession: true,
          usage: UsageTotals(
            records: 40,
            inputTokens: 900000,
            outputTokens: 60000,
            thoughtTokens: 0,
            cachedReadTokens: 0,
            cachedWriteTokens: 0,
            totalTokens: 960000,
            costs: [],
          ),
        );
      final store = _store(api, composerText: 'hi');
      await store.refreshContextUsage();
      await store.sendMessage();
      await pumpEventQueue();
      expect(api.sendCalls, 1);
      expect(store.globalError, isEmpty);
    });

    test('resetContext clears the session flag', () async {
      final api = _FakeApi();
      final store = _store(api);
      await store.load();
      await pumpEventQueue();
      api.usage = const ThreadContextUsage();
      await store.resetContext();
      expect(api.resetCalls, 1);
      await pumpEventQueue();
      expect(store.contextUsage?.hasSession, isFalse);
    });
  });

  group('thread usage indicator', () {
    AppState buildState(
      _FakeApi api, {
      ThreadContextUsage? usage,
      bool sending = false,
    }) => AppState.test(
          api: api,
          sending: sending,
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
          threadContextUsage: usage,
        );

    Widget app(AppState state) => MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux),
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const DropZone(child: ThreadPage()),
      ),
    );

    ThreadContextUsage usage({
      int input = 12000,
      int output = 3500,
      bool hasSession = true,
    }) => ThreadContextUsage(
      hasSession: hasSession,
      usage: UsageTotals(
        records: 4,
        inputTokens: input,
        outputTokens: output,
        thoughtTokens: 0,
        cachedReadTokens: 0,
        cachedWriteTokens: 0,
        totalTokens: input + output,
        costs: const [],
      ),
    );

    testWidgets('shows recorded in/out usage under the composer', (
      tester,
    ) async {
      final api = _FakeApi();
      final state = buildState(api, usage: usage());
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(
        find.byKey(const Key('thread_usage_text')),
      );
      expect(text.data, '12K in · 3.5K out');
    });

    testWidgets('hides until the first fetch completes', (tester) async {
      final api = _FakeApi();
      final state = buildState(api, usage: null);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('thread_usage_indicator')), findsNothing);
    });

    testWidgets('tapping opens the breakdown dialog', (tester) async {
      final api = _FakeApi();
      final state = buildState(api, usage: usage());
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread_usage_indicator')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('12K'), findsOneWidget);
      expect(find.text('4'), findsOneWidget); // turns
      expect(find.byKey(const Key('thread_usage_reset')), findsOneWidget);
    });

    testWidgets('reset button calls the api', (tester) async {
      final api = _FakeApi();
      final state = buildState(api, usage: usage());
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread_usage_indicator')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread_usage_reset')));
      await tester.pumpAndSettle();
      expect(api.resetCalls, 1);
    });

    testWidgets('hides reset without a provider session', (tester) async {
      final api = _FakeApi();
      final state = buildState(api, usage: usage(hasSession: false));
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread_usage_indicator')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('thread_usage_reset')), findsNothing);
    });

    testWidgets('hides reset while a run is active', (tester) async {
      final api = _FakeApi();
      final state = buildState(api, usage: usage(), sending: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('thread_usage_indicator')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('thread_usage_reset')), findsNothing);
    });
  });
}
