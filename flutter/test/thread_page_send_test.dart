import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _SendApiService extends ApiService {
  _SendApiService() : super(client: _ThrowingClient());

  var getThreadCalls = 0;

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
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) {
    getThreadCalls++;
    return Future.value(
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
        totalMessages: 1,
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
  }) async {
    if (afterId == null && beforeId == null && beforeCursor == null) {
      return MessagePage(
        messages: [
          Message(id: 99, role: 'assistant', content: 'server stale message'),
        ],
        total: 1,
      );
    }
    return const MessagePage(messages: [], total: 0);
  }

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

void main() {
  testWidgets('send keeps existing messages and shows the new reply', (
    tester,
  ) async {
    final api = _SendApiService();
    final state = AppState.test(
      api: api,
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
        messages: [Message(id: 1, role: 'user', content: 'existing')],
        totalMessages: 1,
      ),
      composerText: 'hello',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final send = find.widgetWithIcon(IconButton, Icons.send);
    await tester.tap(send);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(api.getThreadCalls, 0);
    expect(find.text('existing'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('Final'), findsOneWidget);
  });
}
