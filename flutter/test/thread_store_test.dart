import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/state/thread_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _TestApiService extends ApiService {
  _TestApiService() : super(client: _ThrowingClient());

  var updateThreadSettingsCalls = 0;
  var getThreadCalls = 0;
  var throwOnUpdateThreadSettings = false;
  var throwOnGetThread = false;

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? model,
    String? permissionMode,
    String? permissions,
  }) {
    updateThreadSettingsCalls++;
    if (throwOnUpdateThreadSettings) {
      return Future.error(Exception('updateThreadSettings failed'));
    }
    return Future.value();
  }

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) {
    getThreadCalls++;
    if (throwOnGetThread) {
      return Future.error(Exception('getThread failed'));
    }
    return Future.value(ThreadDetail(
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
    ));
  }

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async =>
      const MessagePage(messages: [], total: 0);

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) =>
      Stream.fromIterable([
        SseEvent(
          'user_message',
          '{"id": 2, "role": "user", "content": "hello"}',
          id: '1',
        ),
        SseEvent(
          'part',
          '{"type": "text", "content": "Hi"}',
          id: '2',
        ),
        SseEvent(
          'done',
          '{"id": 3, "role": "assistant", "content": "Final"}',
          id: '3',
        ),
      ]);
}

class _RecordingApiService extends _TestApiService {
  String? lastPrompt;
  String? lastMode;

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    lastPrompt = prompt;
    lastMode = mode;
    return const Stream.empty();
  }
}

void main() {
  test('saveSettings reloads detail when none is loaded', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 1);
    expect(store.detail.valueOrNull, isNotNull);
  });

  test('saveSettings does not reload detail when it is already loaded', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      detail: AsyncValue.ready(ThreadDetail(
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
        totalMessages: 0,
      )),
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 0);
  });

  test('saveSettings does not reload detail while it is loading', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      detail: const AsyncValue.loading(),
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 0);
  });

  test('saveSettings does not reload detail after it failed', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      detail: const AsyncValue.error('network error'),
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 0);
  });

  test('saveSettings reports error when updateThreadSettings fails', () async {
    final api = _TestApiService();
    api.throwOnUpdateThreadSettings = true;
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 0);
    expect(store.globalError, isNotEmpty);
  });

  test('saveSettings reports error when reloadDetail fails', () async {
    final api = _TestApiService();
    api.throwOnGetThread = true;
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.getThreadCalls, 1);
    expect(store.globalError, isNotEmpty);
  });

  group('ask prefix handling', () {
    test('sendMessage strips /ask prefix in ask mode', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask  hello world',
        composerMode: ComposerMode.ask,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, 'hello world');
      expect(api.lastMode, 'ask');
    });

    test('sendMessage keeps /ask prefix in non-ask mode', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask hello',
        composerMode: ComposerMode.code,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, '/ask hello');
      expect(api.lastMode, 'code');
    });

    test('sendMessage keeps /ask prefix in plan mode', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask hello',
        composerMode: ComposerMode.plan,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, '/ask hello');
      expect(api.lastMode, 'plan');
    });

    test('sendMessage does not strip glued /ask prefix', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/askhello',
        composerMode: ComposerMode.ask,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, '/askhello');
      expect(api.lastMode, 'ask');
    });

    test('sendMessage returns early when stripped prompt is empty', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask',
        composerMode: ComposerMode.ask,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, isNull);
      expect(store.composerText, '/ask');
    });

    test('sendMessage does not mutate composerText', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask  hello world',
        composerMode: ComposerMode.ask,
        detail: AsyncValue.ready(ThreadDetail(
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
        )),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, 'hello world');
      expect(store.composerText, '/ask  hello world');
    });
  });

  group('turn-windowed pagination', () {
    test('load fetches initial page and stores cursors', () async {
      final api = _CursorApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
      );
      final completer = Completer<void>();
      store.onStateChanged = () {
        if (store.detail.valueOrNull?.messages.length == 2) {
          completer.complete();
        }
      };

      await store.load();
      await completer.future.timeout(const Duration(seconds: 1));

      final d = store.detail.valueOrNull!;
      expect(d.messages, hasLength(2));
      expect(d.totalMessages, 3);
      expect(d.beforeCursor, 'c1');
      expect(d.hasMore, isTrue);
      expect(d.turnLimit, 50);
      expect(d.rawCount, 2);
    });

    test('loadMoreMessages uses beforeCursor and prepends older turns', () async {
      final api = _CursorApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(ThreadDetail(
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
            Message(id: 2, role: 'user', content: 'hello'),
            Message(id: 3, role: 'assistant', content: 'hi'),
          ],
          totalMessages: 3,
          beforeCursor: 'c1',
          hasMore: true,
          turnLimit: 50,
          rawCount: 2,
        )),
      );

      await store.loadMoreMessages();

      final d = store.detail.valueOrNull!;
      expect(d.messages, hasLength(3));
      expect(d.messages.first.id, 1);
      expect(d.messages.first.content, 'older');
      expect(d.beforeCursor, isNull);
      expect(d.hasMore, isFalse);
      expect(d.rawCount, 1);
    });
  });
}

class _CursorApiService extends ApiService {
  _CursorApiService() : super(client: _ThrowingClient());

  var getThreadMessagesCalls = 0;

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) =>
      Future.value(ThreadDetail(
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
        totalMessages: 3,
      ));

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? model,
    String? permissionMode,
    String? permissions,
  }) =>
      Future.value();

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async {
    getThreadMessagesCalls++;
    if (beforeCursor == 'c1') {
      return MessagePage(
        messages: [Message(id: 1, role: 'user', content: 'older')],
        total: 3,
        turnLimit: 50,
        rawCount: 1,
        hasMore: false,
      );
    }
    return MessagePage(
      messages: [
        Message(id: 2, role: 'user', content: 'hello'),
        Message(id: 3, role: 'assistant', content: 'hi'),
      ],
      total: 3,
      turnLimit: 50,
      rawCount: 2,
      beforeCursor: 'c1',
      hasMore: true,
    );
  }
}
