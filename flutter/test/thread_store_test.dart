import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/state/thread_store.dart';
import 'package:devinorium_frontend/utils/debug_log.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
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
  String? lastProvider;
  String threadProviderId = 'devin-cli';

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) {
    updateThreadSettingsCalls++;
    lastProvider = provider;
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
    return Future.value(
      ThreadDetail(
        thread: Thread(
          id: id,
          title: 'Test',
          projectId: 1,
          providerId: threadProviderId,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
        totalMessages: 0,
      ),
    );
  }

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
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => Stream.fromIterable([
    SseEvent(
      'user_message',
      '{"id": 2, "role": "user", "content": "hello"}',
      id: '1',
    ),
    SseEvent('part', '{"type": "text", "content": "Hi"}', id: '2'),
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
  String? lastClientMessageId;

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    lastPrompt = prompt;
    lastMode = mode;
    lastClientMessageId = clientMessageId;
    return const Stream.empty();
  }
}

class _ControlledApiService extends _TestApiService {
  final _controller = StreamController<SseEvent>();

  StreamController<SseEvent> get controller => _controller;

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => _controller.stream;
}

void main() {
  providerSelectionTests();
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

  test(
    'saveSettings does not reload detail when it is already loaded',
    () async {
      final api = _TestApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(
          ThreadDetail(
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
          ),
        ),
        composerText: 'hello',
      );

      await store.saveSettings();

      expect(api.updateThreadSettingsCalls, 1);
      expect(api.getThreadCalls, 0);
    },
  );

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
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
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
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
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
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
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
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
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
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, isNull);
      expect(store.composerText, '/ask');
    });

    test('sendMessage clears composer and shows optimistic message', () async {
      final api = _RecordingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: '/ask  hello world',
        composerMode: ComposerMode.ask,
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
      );

      store.onStateChanged = () {};
      await store.sendMessage();

      expect(api.lastPrompt, 'hello world');
      expect(store.composerText, '');
      final messages = store.displayDetail?.messages ?? [];
      expect(messages, hasLength(1));
      expect(messages.first.role, 'user');
      expect(messages.first.content, 'hello world');
      expect(messages.first.clientMessageId, api.lastClientMessageId);
    });

    test(
      'sendMessage removes optimistic message when server echoes it',
      () async {
        final api = _ControlledApiService();
        final store = ThreadStore(
          api: api,
          threadId: 't1',
          projectId: 1,
          composerText: 'hello',
          detail: AsyncValue.ready(
            ThreadDetail(
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
          ),
        );

        store.onStateChanged = () {};
        await store.sendMessage();

        final clientId = api.controller.hasListener
            ? store.displayDetail?.messages.last.clientMessageId
            : null;
        api.controller.add(
          SseEvent(
            'user_message',
            '{"id": 2, "role": "user", "content": "hello", '
                '"client_message_id": "$clientId"}',
          ),
        );
        await Future.delayed(const Duration(milliseconds: 10));

        final messages = store.displayDetail?.messages ?? [];
        expect(messages, hasLength(1));
        expect(messages.first.id, 2);
        expect(messages.first.clientMessageId, clientId);
      },
    );

    test(
      'sendMessage restores composer when send fails before acknowledgement',
      () async {
        final api = _ControlledApiService();
        final store = ThreadStore(
          api: api,
          threadId: 't1',
          projectId: 1,
          composerText: '/ask  hello',
          composerMode: ComposerMode.ask,
          attachments: [
            (
              filename: 'note.txt',
              mime: 'text/plain',
              bytes: Uint8List.fromList([1, 2, 3]),
            ),
          ],
          detail: AsyncValue.ready(
            ThreadDetail(
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
          ),
        );

        store.onStateChanged = () {};
        await store.sendMessage();
        expect(store.composerText, '');
        expect(store.attachments, isEmpty);

        await api.controller.close();
        await Future.delayed(const Duration(milliseconds: 10));

        expect(store.composerText, '/ask  hello');
        expect(store.attachments, hasLength(1));
        expect(store.displayDetail?.messages ?? [], isEmpty);
      },
    );

    test('sendMessage restores composer on 409 conflict', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
      );

      store.onStateChanged = () {};
      await store.sendMessage();
      expect(store.composerText, '');
      expect(store.displayDetail?.messages, hasLength(1));

      api.controller.addError(ApiException('thread is already running', 409));
      await Future.delayed(const Duration(milliseconds: 10));

      expect(store.composerText, 'hello');
      expect(store.displayDetail?.messages ?? [], isEmpty);
    });

    test(
      'sendMessage replaces existing message when server echoes same id',
      () async {
        final api = _ControlledApiService();
        final store = ThreadStore(
          api: api,
          threadId: 't1',
          projectId: 1,
          composerText: 'optimistic',
          detail: AsyncValue.ready(
            ThreadDetail(
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
                  id: 2,
                  role: 'user',
                  content: 'from refresh',
                  clientMessageId: 'cm-existing',
                ),
              ],
            ),
          ),
        );

        store.onStateChanged = () {};
        await store.sendMessage();
        final clientId = store.displayDetail?.messages.last.clientMessageId;

        api.controller.add(
          SseEvent(
            'user_message',
            '{"id": 2, "role": "user", "content": "hello", '
                '"client_message_id": "$clientId"}',
          ),
        );
        await Future.delayed(const Duration(milliseconds: 10));

        final messages = store.displayDetail?.messages ?? [];
        expect(messages, hasLength(1));
        expect(messages.first.id, 2);
        expect(messages.first.content, 'hello');
        expect(messages.first.clientMessageId, clientId);
      },
    );
  });

  group('thread_update event', () {
    test('updates detail thread and invokes onThreadUpdated', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
            ),
            messages: [],
          ),
        ),
      );

      Thread? updatedThread;
      store.onStateChanged = () {};
      store.onThreadUpdated = (thread) {
        updatedThread = thread;
      };

      await store.sendMessage();
      api.controller.add(
        SseEvent(
          'thread_update',
          '{"title":"New title","updated_at":"2024-01-02T00:00:00.000Z"}',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(store.detail.valueOrNull?.thread.title, 'New title');
      expect(
        store.detail.valueOrNull?.thread.updatedAt,
        '2024-01-02T00:00:00.000Z',
      );
      expect(updatedThread, isNotNull);
      expect(updatedThread!.title, 'New title');
      expect(updatedThread!.updatedAt, '2024-01-02T00:00:00.000Z');
    });

    test('syncs git fields and invokes onThreadUpdated', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
              branch: null,
              worktreePath: null,
              envMode: 'local',
            ),
            messages: [],
          ),
        ),
      );

      Thread? captured;
      store.onStateChanged = () {};
      store.onThreadUpdated = (thread) => captured = thread;

      await store.sendMessage();
      api.controller.add(
        SseEvent(
          'thread_update',
          '{"worktree_path":"/repo/.devinorium-worktrees/wt-1",'
              '"branch":"devinorium/wt-1","env_mode":"worktree"}',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(store.detail.valueOrNull?.thread.title, 'Old');
      expect(store.detail.valueOrNull?.thread.branch, 'devinorium/wt-1');
      expect(
        store.detail.valueOrNull?.thread.worktreePath,
        '/repo/.devinorium-worktrees/wt-1',
      );
      expect(store.detail.valueOrNull?.thread.envMode, 'worktree');
      expect(captured, isNotNull);
      expect(captured!.branch, 'devinorium/wt-1');
      expect(captured!.worktreePath, '/repo/.devinorium-worktrees/wt-1');
      expect(captured!.envMode, 'worktree');
    });

    test('updates thread title and git fields in one event', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        selectedModel: 'm1',
        selectedProvider: 'p1',
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
              branch: null,
              worktreePath: null,
              envMode: 'local',
            ),
            messages: [],
          ),
        ),
      );

      Thread? captured;
      store.onStateChanged = () {};
      store.onThreadUpdated = (thread) => captured = thread;

      await store.sendMessage();
      api.controller.add(
        SseEvent(
          'thread_update',
          '{"title":"New",'
              '"updated_at":"2024-01-02T00:00:00.000Z",'
              '"worktree_path":"/repo/.devinorium-worktrees/wt-1",'
              '"branch":"devinorium/wt-1",'
              '"env_mode":"worktree"}',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(store.detail.valueOrNull?.thread.title, 'New');
      expect(
        store.detail.valueOrNull?.thread.updatedAt,
        '2024-01-02T00:00:00.000Z',
      );
      expect(store.detail.valueOrNull?.thread.branch, 'devinorium/wt-1');
      expect(
        store.detail.valueOrNull?.thread.worktreePath,
        '/repo/.devinorium-worktrees/wt-1',
      );
      expect(store.detail.valueOrNull?.thread.envMode, 'worktree');
      expect(captured, isNotNull);
      expect(captured!.title, 'New');
      expect(captured!.branch, 'devinorium/wt-1');
      expect(captured!.worktreePath, '/repo/.devinorium-worktrees/wt-1');
      expect(captured!.envMode, 'worktree');
    });

    test('does not invoke callback when metadata is unchanged', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Same',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
            ),
            messages: [],
          ),
        ),
      );

      Thread? captured;
      store.onStateChanged = () {};
      store.onThreadUpdated = (thread) => captured = thread;

      await store.sendMessage();
      api.controller.add(
        SseEvent(
          'thread_update',
          '{"title":"Same","updated_at":"2024-01-01T00:00:00.000Z"}',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(captured, isNull);
    });

    test('does not invoke callback for duplicate git thread_update', () async {
      final api = _ControlledApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
              branch: 'devinorium/wt-1',
              worktreePath: '/repo/.devinorium-worktrees/wt-1',
              envMode: 'worktree',
            ),
            messages: [],
          ),
        ),
      );

      Thread? captured;
      store.onStateChanged = () {};
      store.onThreadUpdated = (thread) => captured = thread;

      await store.sendMessage();
      api.controller.add(
        SseEvent(
          'thread_update',
          '{"worktree_path":"/repo/.devinorium-worktrees/wt-1",'
              '"branch":"devinorium/wt-1","env_mode":"worktree"}',
        ),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(captured, isNull);
      expect(
        store.detail.valueOrNull?.thread.worktreePath,
        '/repo/.devinorium-worktrees/wt-1',
      );
    });

    test('nulls onThreadUpdated and onRunFinished on dispose', () {
      final api = _ControlledApiService();
      final store = ThreadStore(api: api, threadId: 't1', projectId: 1);

      store.onThreadUpdated = (_) {};
      store.onRunFinished = (_) {};
      store.dispose();

      expect(store.onThreadUpdated, isNull);
      expect(store.onRunFinished, isNull);
    });
  });

  group('reloadDetail', () {
    test('preserves loaded messages and paging cursors', () async {
      final api = _ReloadApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old title',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '',
            ),
            messages: [
              Message(id: 1, role: 'user', content: 'hello'),
              Message(id: 2, role: 'assistant', content: 'hi'),
            ],
            totalMessages: 2,
            beforeCursor: 'c1',
            hasMore: true,
            turnLimit: 50,
            rawCount: 2,
          ),
        ),
      );
      store.onStateChanged = () {};

      await store.reloadDetail();

      final d = store.detail.valueOrNull!;
      expect(d.messages, hasLength(2));
      expect(d.messages.first.id, 1);
      expect(d.beforeCursor, 'c1');
      expect(d.hasMore, isTrue);
      expect(d.turnLimit, 50);
      expect(d.rawCount, 2);
      expect(d.thread.title, 'New title');
      expect(api.getThreadMessagesCalls, 0);
    });

    test('updates thread metadata without dropping messages', () async {
      final api = _ReloadApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '2024-01-01T00:00:00.000Z',
            ),
            messages: [Message(id: 1, role: 'user', content: 'hi')],
            totalMessages: 1,
          ),
        ),
      );
      store.onStateChanged = () {};

      await store.reloadDetail();

      final d = store.detail.valueOrNull!;
      expect(d.thread.title, 'New title');
      expect(d.thread.updatedAt, '2024-02-01T00:00:00.000Z');
      expect(d.messages, hasLength(1));
      expect(d.totalMessages, 2);
    });

    test('loads initial messages when detail has no messages', () async {
      final api = _ReloadApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(
          ThreadDetail(
            thread: Thread(
              id: 't1',
              title: 'Old',
              projectId: 1,
              model: 'm1',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '',
            ),
            messages: const [],
            totalMessages: 2,
          ),
        ),
      );
      final completer = Completer<void>();
      store.onStateChanged = () {
        if (store.detail.valueOrNull?.messages.length == 2) {
          completer.complete();
        }
      };

      await store.reloadDetail();
      await completer.future.timeout(const Duration(seconds: 1));

      expect(store.detail.valueOrNull!.messages, hasLength(2));
      expect(api.getThreadMessagesCalls, 1);
    });

    test('loads initial messages when detail is empty', () async {
      final api = _ReloadApiService();
      final store = ThreadStore(api: api, threadId: 't1', projectId: 1);
      final completer = Completer<void>();
      store.onStateChanged = () {
        if (store.detail.valueOrNull?.messages.length == 2) {
          completer.complete();
        }
      };

      await store.reloadDetail();
      await completer.future.timeout(const Duration(seconds: 1));

      expect(store.detail.valueOrNull!.messages, hasLength(2));
      expect(api.getThreadMessagesCalls, 1);
    });
  });

  group('turn-windowed pagination', () {
    test('load fetches initial page and stores cursors', () async {
      final api = _CursorApiService();
      final store = ThreadStore(api: api, threadId: 't1', projectId: 1);
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

    test(
      'loadMoreMessages uses beforeCursor and prepends older turns',
      () async {
        final api = _CursorApiService();
        final store = ThreadStore(
          api: api,
          threadId: 't1',
          projectId: 1,
          detail: AsyncValue.ready(
            ThreadDetail(
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
            ),
          ),
        );

        await store.loadMoreMessages();

        final d = store.detail.valueOrNull!;
        expect(d.messages, hasLength(3));
        expect(d.messages.first.id, 1);
        expect(d.messages.first.content, 'older');
        expect(d.beforeCursor, isNull);
        expect(d.hasMore, isFalse);
        expect(d.rawCount, 1);
      },
    );
  });

  group('debug failure logging', () {
    test('debugLogFailure emits the expected format in debug mode', () {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      debugLogFailure('unit.test', 'boom', threadId: 't9');

      expect(logs, hasLength(1));
      expect(
        logs.single,
        matches(RegExp(r'^\[devinorium\] unit\.test failed thread=t9: boom$')),
      );
    });

    test('debugLogFailure omits thread segment when threadId is null', () {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      debugLogFailure('unit.test', 'boom');

      expect(logs, hasLength(1));
      expect(
        logs.single,
        matches(RegExp(r'^\[devinorium\] unit\.test failed: boom$')),
      );
    });

    test('saveSettings logs failure via debugPrint in debug mode', () async {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      final api = _TestApiService();
      api.throwOnUpdateThreadSettings = true;
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        composerText: 'hello',
      );

      await store.saveSettings();

      expect(store.globalError, isNotEmpty);
      expect(
        logs,
        anyElement(matches(RegExp(r'thread\.saveSettings failed.*t1'))),
      );
    });

    test('load logs failure via debugPrint in debug mode', () async {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      final api = _TestApiService();
      api.throwOnGetThread = true;
      final store = ThreadStore(api: api, threadId: 't1', projectId: 1);

      await store.load();

      expect(store.status, ThreadStoreStatus.error);
      expect(logs, anyElement(matches(RegExp(r'thread\.load failed.*t1'))));
    });

    test('stop logs failure via debugPrint in debug mode', () async {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      final api = _StopFailingApiService();
      final store = ThreadStore(
        api: api,
        threadId: 't1',
        projectId: 1,
        detail: AsyncValue.ready(
          ThreadDetail(
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
        ),
      );
      store.onStateChanged = () {};

      await store.stop();

      expect(store.globalError, isNotEmpty);
      expect(logs, anyElement(matches(RegExp(r'thread\.stop failed.*t1'))));
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
      totalMessages: 3,
    ),
  );

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

class _StopFailingApiService extends _TestApiService {
  @override
  Future<void> stopThread(String id) =>
      Future.error(Exception('stopThread failed'));
}

class _ReloadApiService extends ApiService {
  _ReloadApiService() : super(client: _ThrowingClient());

  var getThreadMessagesCalls = 0;

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) => Future.value(
    ThreadDetail(
      thread: Thread(
        id: id,
        title: 'New title',
        projectId: 1,
        model: 'm1',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '2024-02-01T00:00:00.000Z',
      ),
      messages: const [],
      totalMessages: 2,
    ),
  );

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
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async {
    getThreadMessagesCalls++;
    return MessagePage(
      messages: [
        Message(id: 1, role: 'user', content: 'hello'),
        Message(id: 2, role: 'assistant', content: 'hi'),
      ],
      total: 2,
      turnLimit: 50,
      rawCount: 2,
      beforeCursor: 'c1',
      hasMore: false,
    );
  }
}

void providerSelectionTests() {
  test('saveSettings sends the selected provider', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      selectedProvider: 'opencode',
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.updateThreadSettingsCalls, 1);
    expect(api.lastProvider, 'opencode');
  });

  test('saveSettings omits provider when unset', () async {
    final api = _TestApiService();
    final store = ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      composerText: 'hello',
    );

    await store.saveSettings();

    expect(api.lastProvider, isNull);
  });

  test('load seeds the provider from the thread', () async {
    final api = _TestApiService()..threadProviderId = 'opencode';
    final store = ThreadStore(api: api, threadId: 't1', projectId: 1);

    await store.load();

    expect(store.selectedProvider, 'opencode');
  });
}
