import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _MessageItemApiService extends ApiService {
  _MessageItemApiService() : super(client: _ThrowingClient());

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
        totalMessages: 1,
      ));

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? permissions,
  }) =>
      Future.value();

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

  @override
  Future<void> stopThread(String id) => Future.value();

  @override
  Future<Message> getMessageChunk(
    String threadId,
    int messageId, {
    int offset = 0,
    int limit = 100000,
  }) async {
    final full = 'full content ' * 20;
    if (offset == 0) {
      return Message(
        id: messageId,
        role: 'assistant',
        content: 'short preview',
        truncated: true,
        totalChars: 'short preview'.runes.length + full.runes.length,
      );
    }
    return Message(
      id: messageId,
      role: 'assistant',
      content: full,
      truncated: false,
      totalChars: 'short preview'.runes.length + full.runes.length,
    );
  }
}

void main() {
  testWidgets('long user message shows Show more and expands in place', (
    tester,
  ) async {
    final state = AppState.test(
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
            content: 'a' * 700,
          ),
        ],
        totalMessages: 1,
      ),
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

    expect(find.text('Show more'), findsOneWidget);

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('truncated assistant message loads chunks on visibility', (
    tester,
  ) async {
    final api = _MessageItemApiService();
    final full = 'full content ' * 20;
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
        messages: [
          Message(
            id: 1,
            role: 'assistant',
            content: 'short preview',
            truncated: true,
            totalChars: 'short preview'.runes.length + full.runes.length,
          ),
        ],
        totalMessages: 1,
      ),
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

    expect(find.text('Show full message'), findsNothing);
    expect(find.text('Loading more…'), findsNothing);

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody).first);
    expect(markdown.data, contains('full content'));
  });
}
