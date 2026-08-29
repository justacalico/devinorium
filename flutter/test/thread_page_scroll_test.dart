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

class _PaginatedApiService extends ApiService {
  final List<Message> initial;
  final List<Message> older;

  _PaginatedApiService({
    required this.initial,
    required this.older,
  }) : super(client: _ThrowingClient());

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async {
    if (afterId != null) {
      return MessagePage(messages: const [], total: initial.length + older.length);
    }
    if (beforeId == initial.first.id || beforeCursor == 'c1') {
      return MessagePage(
        messages: older,
        total: initial.length + older.length,
        hasMore: false,
      );
    }
    return MessagePage(
      messages: initial,
      total: initial.length + older.length,
      beforeCursor: 'c1',
      hasMore: true,
    );
  }
}

void main() {
  final longMessages = List.generate(
    50,
    (i) => Message(
      id: i,
      role: i.isEven ? 'user' : 'assistant',
      content: 'Message $i\n${'more text ' * 100}',
    ),
  );

  Widget buildWithState(AppState state) => MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const ThreadPage(),
        ),
      );

  testWidgets('opening a long thread starts at the newest message', (
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
        messages: longMessages,
        totalMessages: longMessages.length,
      ),
    );

    await tester.pumpWidget(buildWithState(state));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, 0);
    expect(find.textContaining('Message 49'), findsOneWidget);
  });

  testWidgets('sending a message while at the top scrolls to the bottom', (
    tester,
  ) async {
    final state = AppState.test(
      activeThreadId: 't1',
      sending: true,
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
        messages: longMessages,
        totalMessages: longMessages.length,
      ),
    );

    await tester.pumpWidget(buildWithState(state));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );

    // Start at the bottom.
    expect(find.textContaining('Message 49'), findsOneWidget);

    // Scroll to the top (oldest messages).
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(find.textContaining('Message 0'), findsOneWidget);
    expect(find.textContaining('Message 49'), findsNothing);

    // A new message while the stream is active should bring the view back down.
    expect(state.sending, isTrue);
    state.activeThreadDetail!.messages.add(
      Message(
        id: 50,
        role: 'assistant',
        content: 'Message 50\n${'more text ' * 100}',
      ),
    );
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.textContaining('Message 50'), findsOneWidget);
    expect(find.textContaining('Message 0'), findsNothing);
    expect(scrollable.position.pixels, 0);
  });

  testWidgets('scrolling back to the bottom re-enables auto-scroll', (
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
        messages: longMessages,
        totalMessages: longMessages.length,
      ),
    );

    await tester.pumpWidget(buildWithState(state));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );

    // Scroll away from the bottom and back.
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();

    // A new message while at the bottom should stay visible.
    state.activeThreadDetail!.messages.add(
      Message(
        id: 50,
        role: 'assistant',
        content: 'Message 50\n${'more text ' * 100}',
      ),
    );
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.textContaining('Message 50'), findsOneWidget);
    expect(scrollable.position.pixels, 0);
  });

  testWidgets('loading older messages keeps the view near the top', (
    tester,
  ) async {
    final initial = List.generate(
      50,
      (i) => Message(
        id: i + 50,
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message ${i + 50}\n${'more text ' * 100}',
      ),
    );
    final older = List.generate(
      50,
      (i) => Message(
        id: i,
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message $i\n${'more text ' * 100}',
      ),
    );

    final state = AppState.test(
      activeThreadId: 't1',
      api: _PaginatedApiService(initial: initial, older: older),
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
        messages: initial,
        totalMessages: initial.length + older.length,
      ),
    );

    await tester.pumpWidget(buildWithState(state));
    await tester.pumpAndSettle();

    // Scroll to the top to trigger loadMore.
    await tester.drag(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      const Offset(0, 30000),
    );
    await tester.pumpAndSettle();

    // The oldest of the newly loaded messages should now be visible.
    expect(find.textContaining('Message 0'), findsOneWidget);
  });

  testWidgets('can scroll back down after loading older messages', (
    tester,
  ) async {
    final initial = List.generate(
      50,
      (i) => Message(
        id: i + 50,
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message ${i + 50}\n${'more text ' * 100}',
      ),
    );
    final older = List.generate(
      50,
      (i) => Message(
        id: i,
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message $i\n${'more text ' * 100}',
      ),
    );

    final state = AppState.test(
      activeThreadId: 't1',
      api: _PaginatedApiService(initial: initial, older: older),
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
        messages: initial,
        totalMessages: initial.length + older.length,
      ),
    );

    await tester.pumpWidget(buildWithState(state));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );

    // Scroll to the very top.
    await tester.drag(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      const Offset(0, 30000),
    );
    await tester.pumpAndSettle();

    final topPosition = scrollable.position.pixels;
    expect(find.textContaining('Message 0'), findsOneWidget);

    // Scroll back to the bottom.
    await tester.drag(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      const Offset(0, -30000),
    );
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, lessThan(topPosition));
    // The view should have moved down enough to leave the oldest message.
    expect(find.textContaining('Message 0'), findsNothing);
  });
}
