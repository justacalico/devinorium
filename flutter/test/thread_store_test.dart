import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
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
  Future<ThreadDetail> getThread(String id, {bool includeMessages = false}) {
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
  Future<List<Message>> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int limit = 50,
  }) async =>
      const [];

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
}
