import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:devinorium_frontend/widgets/attachment_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  var resendCalls = 0;
  int? lastResendMessageId;
  String? lastEditedPrompt;

  @override
  Stream<SseEvent> resendMessageStream({
    required String threadId,
    required int messageId,
    String? editedPrompt,
    String? mode,
    String? clientMessageId,
  }) {
    resendCalls++;
    lastResendMessageId = messageId;
    lastEditedPrompt = editedPrompt;
    return const Stream.empty();
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

  testWidgets('thinking runs separated by tools render as distinct blocks', (
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
            role: 'assistant',
            content: 'done',
            parts: [
              MessagePart.thinking(content: 'Let me look at the repo.'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 't1',
                  title: 'list files',
                  kind: 'execute',
                  status: 'completed',
                ),
              ),
              MessagePart.thinking(content: 'Now I know the layout.'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 't2',
                  title: 'edit main.rs',
                  kind: 'search',
                  status: 'completed',
                ),
              ),
              MessagePart.text(content: 'done'),
            ],
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

    expect(find.text('Show thinking'), findsNWidgets(2));
    expect(find.text('list files'), findsOneWidget);
    expect(find.text('edit main.rs'), findsOneWidget);
  });

  testWidgets('consecutive finished tools collapse into a group row', (
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
            role: 'assistant',
            content: 'done',
            parts: [
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'r1',
                  title: 'read a',
                  kind: 'read',
                  status: 'completed',
                  command: '{"file_path": "/repo/a.rs"}',
                ),
              ),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'r2',
                  title: 'read b',
                  kind: 'read',
                  status: 'completed',
                  command: '{"file_path": "/repo/b.rs"}',
                ),
              ),
              MessagePart.text(content: 'done'),
            ],
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

    expect(find.text('Read 2 files'), findsOneWidget);
    expect(find.text('Read a.rs'), findsNothing);

    await tester.tap(find.text('Read 2 files'));
    await tester.pumpAndSettle();

    expect(find.text('Read a.rs'), findsOneWidget);
    expect(find.text('Read b.rs'), findsOneWidget);
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

  ThreadDetail detailWith(List<Message> messages) => ThreadDetail(
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
    totalMessages: messages.length,
  );

  Future<void> pumpThread(
    WidgetTester tester,
    AppState state,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('message header shows the send time', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(
          id: 1,
          role: 'user',
          content: 'hi',
          createdAt: DateTime.now(),
        ),
      ]),
    );

    await pumpThread(tester, state);

    expect(find.textContaining('You ·'), findsOneWidget);
  });

  testWidgets('copy action puts the message text on the clipboard', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(id: 1, role: 'assistant', content: 'the answer'),
      ]),
    );

    await pumpThread(tester, state);
    await tester.tap(find.byIcon(Icons.content_copy_outlined));
    await tester.pump();

    expect(copied, 'the answer');
  });

  testWidgets('regenerate action resends the last reply', (tester) async {
    final api = _MessageItemApiService();
    final state = AppState.test(
      api: api,
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(id: 1, role: 'user', content: 'one'),
        Message(id: 2, role: 'assistant', content: 'r1'),
      ]),
    );

    await pumpThread(tester, state);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(api.resendCalls, 1);
    expect(api.lastResendMessageId, 2);
    expect(api.lastEditedPrompt, isNull);
  });

  testWidgets('no regenerate action on a non-final reply', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(id: 1, role: 'user', content: 'one'),
        Message(id: 2, role: 'assistant', content: 'r1'),
        Message(id: 3, role: 'user', content: 'two'),
        Message(id: 4, role: 'assistant', content: 'r2'),
      ]),
    );

    await pumpThread(tester, state);

    // Only the last assistant message gets the refresh action.
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('edit action resends the edited prompt', (tester) async {
    final api = _MessageItemApiService();
    final state = AppState.test(
      api: api,
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(id: 1, role: 'user', content: 'original'),
      ]),
    );

    await pumpThread(tester, state);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Edit message'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'fixed text',
    );
    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();

    expect(api.resendCalls, 1);
    expect(api.lastResendMessageId, 1);
    expect(api.lastEditedPrompt, 'fixed text');
  });

  testWidgets('messages from different days get date separators', (
    tester,
  ) async {
    final now = DateTime.now();
    final state = AppState.test(
      activeThreadId: 't1',
      activeThreadDetail: detailWith([
        Message(
          id: 1,
          role: 'user',
          content: 'old',
          createdAt: now.subtract(const Duration(days: 1)),
        ),
        Message(
          id: 2,
          role: 'assistant',
          content: 'new',
          createdAt: now,
        ),
      ]),
    );

    await pumpThread(tester, state);

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });
}
