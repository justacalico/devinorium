import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:devinorium_frontend/widgets/attachment_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// A 1x1 transparent PNG.
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _MessageItemApiService extends ApiService {
  _MessageItemApiService() : super(client: _ThrowingClient());

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
      totalMessages: 1,
    ),
  );

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

class _AttachmentApiService extends _MessageItemApiService {
  bool failAttachment = false;
  int attachmentCalls = 0;

  @override
  Future<({String filename, String mime, Uint8List bytes})>
  getMessageAttachment(String threadId, int messageId, int index) {
    attachmentCalls++;
    if (failAttachment) throw ApiException('gone', 404);
    return Future.value(
      (filename: 'shot.png', mime: 'image/png', bytes: _png1x1),
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
        messages: [Message(id: 1, role: 'user', content: 'a' * 700)],
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

    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    expect(markdown.data, contains('full content'));
  });

  AppState attachmentState(
    ApiService api,
    List<Message> messages,
  ) => AppState.test(
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
      messages: messages,
      totalMessages: 1,
    ),
  );

  testWidgets('image attachment fetches blob and renders thumbnail', (
    tester,
  ) async {
    final api = _AttachmentApiService();
    final state = attachmentState(api, [
      Message(
        id: 7,
        role: 'user',
        content: 'see this',
        attachments: [
          Attachment(
            filename: 'shot.png',
            size: 3,
            mime: 'image/png',
            index: 0,
          ),
        ],
      ),
    ]);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.attachmentCalls, 1);
    expect(find.byType(AttachmentThumb), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);
  });

  testWidgets('failed attachment fetch keeps the filename chip', (
    tester,
  ) async {
    final api = _AttachmentApiService()..failAttachment = true;
    final state = attachmentState(api, [
      Message(
        id: 7,
        role: 'user',
        content: 'see this',
        attachments: [
          Attachment(
            filename: 'gone.png',
            size: 3,
            mime: 'image/png',
            index: 0,
          ),
        ],
      ),
    ]);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AttachmentThumb), findsNothing);
    expect(find.text('gone.png'), findsOneWidget);
  });

  testWidgets('optimistic image attachment shows thumbnail without fetch', (
    tester,
  ) async {
    final api = _AttachmentApiService();
    final state = attachmentState(api, [
      Message(
        role: 'user',
        content: 'unsent',
        attachments: [
          Attachment(
            filename: 'local.png',
            size: _png1x1.length,
            mime: 'image/png',
            bytes: _png1x1,
          ),
        ],
      ),
    ]);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.attachmentCalls, 0);
    expect(find.byType(AttachmentThumb), findsOneWidget);
  });

  testWidgets('non-image and ref attachments keep chips', (tester) async {
    final api = _AttachmentApiService();
    final state = attachmentState(api, [
      Message(
        id: 7,
        role: 'user',
        content: 'ctx',
        attachments: [
          Attachment(
            filename: 'doc.txt',
            size: 3,
            mime: 'text/plain',
            index: 1,
          ),
          Attachment(
            filename: 'src/x.rs',
            size: 0,
            mime: 'application/x-devinorium-path',
            isPathRef: true,
          ),
        ],
      ),
    ]);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.attachmentCalls, 0);
    expect(find.byType(AttachmentThumb), findsNothing);
    expect(find.text('doc.txt'), findsOneWidget);
    expect(find.text('src/x.rs'), findsOneWidget);
  });
}
