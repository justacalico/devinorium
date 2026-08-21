import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/elapsed_time_indicator.dart';
import 'package:devinorium_frontend/views/model_picker.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(false);

  @override
  Future<Map<String, dynamic>> get(String path) => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getList(String path) =>
      throw UnimplementedError();

  @override
  Stream<SseEvent> getStream({required String path}) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) => throw UnimplementedError();

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
  }) => throw UnimplementedError();

  @override
  Future<void> setServerUrl(String serverUrl) => Future.value();

  @override
  Future<void> setToken(String token) => Future.value();

  @override
  Future<void> setUsername(String username) => Future.value();

  @override
  Future<void> clearCredentials() => Future.value();

  @override
  Future<void> init() => Future.value();

  @override
  bool get isNative => true;

  @override
  Future<String?> get serverUrl => Future.value(null);
}

class _FakeApiService extends ApiService {
  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? model,
    String? permissionMode,
    String? permissions,
  }) => Future.value();

  @override
  Future<ThreadDetail> getThread(String id, {bool includeMessages = false}) => Future.value(
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
      messages: [],
    ),
  );

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => Stream.fromFuture(Future.value(SseEvent('done', '')));

  @override
  Future<void> stopThread(String id) => Future.value();
}

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

void main() {
  testWidgets(
    'Model picker and permission dropdown are disabled without a thread',
    (tester) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        models: [
          ModelInfo(
            id: 'm1',
            label: 'Model 1',
            costTier: 'free',
            family: 'test',
          ),
        ],
      );
      state.setSelectedModel('m1');
      state.setSelectedPermission('normal');

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final modelPicker = find.byType(ModelPicker);
      final dropdown = find.byType(DropdownButton<String>);

      expect(modelPicker, findsOneWidget);
      expect(dropdown, findsOneWidget);

      final button = tester.widget<DropdownButton<String>>(dropdown);
      expect(button.onChanged, isNull);

      await tester.tap(modelPicker);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'Model picker and permission dropdown are disabled while sending',
    (tester) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        models: [
          ModelInfo(
            id: 'm1',
            label: 'Model 1',
            costTier: 'free',
            family: 'test',
          ),
        ],
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test thread',
            projectId: 1,
            model: 'm1',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        ),
        sending: true,
      );
      state.setSelectedModel('m1');
      state.setSelectedPermission('normal');

      await tester.pumpWidget(_buildWithState(state));
      await tester.pump();

      final modelPicker = find.byType(ModelPicker);
      final dropdown = find.byType(DropdownButton<String>);

      expect(modelPicker, findsOneWidget);
      expect(dropdown, findsOneWidget);

      final button = tester.widget<DropdownButton<String>>(dropdown);
      expect(button.onChanged, isNull);

      await tester.tap(modelPicker);
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'Model picker and permission dropdown are enabled with an active thread',
    (tester) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        models: [
          ModelInfo(
            id: 'm1',
            label: 'Model 1',
            costTier: 'free',
            family: 'test',
          ),
        ],
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test thread',
            projectId: 1,
            model: 'm1',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        ),
      );
      state.setSelectedModel('m1');
      state.setSelectedPermission('normal');

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final modelPicker = find.byType(ModelPicker);
      final dropdown = find.byType(DropdownButton<String>);

      expect(modelPicker, findsOneWidget);
      expect(dropdown, findsOneWidget);

      final button = tester.widget<DropdownButton<String>>(dropdown);
      expect(button.onChanged, isNotNull);

      await tester.tap(modelPicker);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    },
  );

  testWidgets('renders thinking, text and tool call parts in order', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'hmm'),
              MessagePart.text(content: 'hello'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-1',
                  title: 'Run cmd',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
              MessagePart.text(content: ' done'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('hmm'), findsOneWidget);
    expect(find.text('Run cmd'), findsOneWidget);

    final markdowns = find.byType(MarkdownBody);
    expect(markdowns, findsNWidgets(2));
    expect(tester.widget<MarkdownBody>(markdowns.at(0)).data, 'hello');
    expect(tester.widget<MarkdownBody>(markdowns.at(1)).data, ' done');
  });

  testWidgets('tool calls render inside the expanded thinking block', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'hmm'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-1',
                  title: 'Run cmd',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-2',
                  title: 'Run another',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo world',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('hmm'), findsOneWidget);
    expect(find.text('Run cmd'), findsOneWidget);
    expect(find.text('Run another'), findsOneWidget);
  });

  testWidgets('edit tool calls render outside the thinking block', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'let me edit the file'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-edit-1',
                  title: 'Edit main.rs',
                  kind: 'edit',
                  status: 'completed',
                  diffs: [
                    FileDiff(
                      path: '/tmp/src/main.rs',
                      oldText: 'fn main() {}',
                      newText: 'fn main() { println!("hi"); }',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // The edit tool card is rendered (EditFileTool shows the filename).
    expect(find.textContaining('main.rs'), findsOneWidget);

    // The thinking block is collapsed (not working, no text) so it shows
    // the "Show thinking" label instead of "Hide thinking".
    expect(find.text('Show thinking'), findsOneWidget);
  });

  testWidgets('edit tool calls render outside thinking even when collapsed', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: 'Done editing',
            parts: [
              MessagePart.thinking(content: 'thinking about it'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-edit-1',
                  title: 'Edit lib.rs',
                  kind: 'edit',
                  status: 'completed',
                  diffs: [
                    FileDiff(
                      path: '/tmp/src/lib.rs',
                      oldText: 'old',
                      newText: 'new',
                    ),
                  ],
                ),
              ),
              MessagePart.text(content: 'Done editing'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Edit tool card is visible without expanding thinking.
    expect(find.textContaining('lib.rs'), findsOneWidget);
    // Thinking is collapsed (hasText=true so it auto-collapses).
    expect(find.text('Show thinking'), findsOneWidget);
    // Reply text is visible.
    expect(find.text('Done editing'), findsOneWidget);
  });

  testWidgets('edit tool call between two thinking blocks renders outside both', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'first think'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-edit-1',
                  title: 'Edit a.rs',
                  kind: 'edit',
                  status: 'completed',
                  diffs: [
                    FileDiff(path: '/tmp/a.rs', oldText: 'a', newText: 'b'),
                  ],
                ),
              ),
              MessagePart.thinking(content: 'second think'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Edit tool card visible without expanding either thinking block.
    expect(find.textContaining('a.rs'), findsOneWidget);
    // Both thinking blocks are collapsed (no text, not working).
    expect(find.text('Show thinking'), findsNWidgets(2));
  });

  testWidgets('execute tool calls render outside the thinking block', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'let me run a command'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-exec-1',
                  title: 'Run cmd',
                  kind: 'execute',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Execute tool card shows the command, visible without expanding thinking.
    expect(find.textContaining('echo hello'), findsOneWidget);
    // Thinking is collapsed.
    expect(find.text('Show thinking'), findsOneWidget);
  });

  testWidgets('execute tool calls render outside thinking even with text', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: 'Finished',
            parts: [
              MessagePart.thinking(content: 'thinking about it'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-exec-1',
                  title: 'Run cmd',
                  kind: 'execute',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
              MessagePart.text(content: 'Finished'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Execute tool card shows the command, visible without expanding thinking.
    expect(find.textContaining('echo hello'), findsOneWidget);
    // Thinking is collapsed (hasText=true).
    expect(find.text('Show thinking'), findsOneWidget);
    // Reply text is visible.
    expect(find.text('Finished'), findsOneWidget);
  });

  testWidgets('execute tool call between two thinking blocks renders outside both', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'first think'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-exec-1',
                  title: 'Run cmd',
                  kind: 'execute',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
              MessagePart.thinking(content: 'second think'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Execute tool card shows the command, visible without expanding either thinking block.
    expect(find.textContaining('echo hello'), findsOneWidget);
    // Both thinking blocks are collapsed.
    expect(find.text('Show thinking'), findsNWidgets(2));
  });

  testWidgets('interleaves thinking text and tool calls in order', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'let me search'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-1',
                  title: 'search',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo search',
                ),
              ),
              MessagePart.thinking(content: 'ok let me read'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-2',
                  title: 'read file',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo read',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('let me search'), findsOneWidget);
    expect(find.text('ok let me read'), findsOneWidget);
    expect(find.text('search'), findsOneWidget);
    expect(find.text('read file'), findsOneWidget);
  });

  testWidgets('merges consecutive thinking parts before a tool call', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'hmm1'),
              MessagePart.thinking(content: 'hmm2'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-1',
                  title: 'search',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo search',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('hmm1hmm2'), findsOneWidget);
    expect(find.text('search'), findsOneWidget);
  });

  testWidgets('interleaves multiple thinking and text blocks in order', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(
                content: 'let me switch to branch this-thing',
              ),
              MessagePart.text(content: 'switched to branch this-thing'),
              MessagePart.thinking(
                content: 'ok done let me do the change now',
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('let me switch to branch this-thing'), findsOneWidget);
    expect(find.text('switched to branch this-thing'), findsOneWidget);
    expect(find.text('ok done let me do the change now'), findsOneWidget);

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(AnimatedCrossFade), findsNWidgets(2));

    final firstThinking = tester.getCenter(
      find.ancestor(
        of: find.text('let me switch to branch this-thing'),
        matching: find.byType(AnimatedCrossFade),
      ),
    );
    final textCenter = tester.getCenter(find.byType(MarkdownBody));
    final secondThinking = tester.getCenter(
      find.ancestor(
        of: find.text('ok done let me do the change now'),
        matching: find.byType(AnimatedCrossFade),
      ),
    );

    expect(firstThinking.dy, lessThan(textCenter.dy));
    expect(textCenter.dy, lessThan(secondThinking.dy));
  });

  testWidgets('keeps tool calls with their preceding thinking group when interleaved', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'first think'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-1',
                  title: 'Run a',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo a',
                ),
              ),
              MessagePart.text(content: 'middle text'),
              MessagePart.thinking(content: 'second think'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-2',
                  title: 'Run b',
                  kind: 'search',
                  status: 'completed',
                  command: 'echo b',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.byType(AnimatedCrossFade), findsNWidgets(2));
    expect(find.byType(MarkdownBody), findsOneWidget);

    final firstBlock = tester.getCenter(
      find.ancestor(
        of: find.text('Run a'),
        matching: find.byType(AnimatedCrossFade),
      ),
    );
    final textCenter = tester.getCenter(find.byType(MarkdownBody));
    final secondBlock = tester.getCenter(
      find.ancestor(
        of: find.text('Run b'),
        matching: find.byType(AnimatedCrossFade),
      ),
    );

    expect(firstBlock.dy, lessThan(textCenter.dy));
    expect(textCenter.dy, lessThan(secondBlock.dy));
  });

  testWidgets('each thinking block expands and collapses independently', (
    tester,
  ) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '',
            parts: [
              MessagePart.thinking(content: 'first think'),
              MessagePart.text(content: 'middle'),
              MessagePart.thinking(content: 'second think'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final toggles = find.text('Show thinking');
    expect(toggles, findsNWidgets(2));

    await tester.tap(toggles.first);
    await tester.pumpAndSettle();

    expect(find.text('Hide thinking'), findsOneWidget);
    expect(find.text('Show thinking'), findsOneWidget);

    await tester.tap(find.text('Show thinking'));
    await tester.pumpAndSettle();

    expect(find.text('Hide thinking'), findsNWidgets(2));

    await tester.tap(find.text('Hide thinking').first);
    await tester.pumpAndSettle();

    expect(find.text('Show thinking'), findsOneWidget);
    expect(find.text('Hide thinking'), findsOneWidget);
  });

  testWidgets('tapping assistant markdown link opens the url', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch') {
            final args = call.arguments as Map<dynamic, dynamic>;
            launched.add(args['url'] as String);
            return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'assistant',
            content: '[example](https://example.com)',
            parts: [
              MessagePart.text(content: '[example](https://example.com)'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final text = find.descendant(
      of: find.byType(MarkdownBody),
      matching: find.byType(Text),
    );
    expect(text, findsOneWidget);
    final widget = tester.widget<Text>(text);
    final span = widget.textSpan! as TextSpan;
    TapGestureRecognizer? linkRecognizer;
    span.visitChildren((inline) {
      if (inline is TextSpan && inline.recognizer is TapGestureRecognizer) {
        final text = inline.text ?? '';
        if (text == 'example' && linkRecognizer == null) {
          linkRecognizer = inline.recognizer as TapGestureRecognizer;
        }
      }
      return true;
    });
    expect(linkRecognizer, isNotNull);
    linkRecognizer!.onTap!();

    expect(launched, ['https://example.com']);
  });

  testWidgets('tapping user linkified text opens the url', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'launch') {
            final args = call.arguments as Map<dynamic, dynamic>;
            launched.add(args['url'] as String);
            return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(
            role: 'user',
            content: 'see https://example.com',
            parts: [MessagePart.text(content: 'see https://example.com')],
          ),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final rich = find.descendant(
      of: find.byType(Linkify),
      matching: find.byType(RichText),
    );
    expect(rich, findsOneWidget);
    final widget = tester.widget<RichText>(rich);
    final span = widget.text as TextSpan;
    TapGestureRecognizer? linkRecognizer;
    span.visitChildren((inline) {
      if (inline is TextSpan && inline.recognizer is TapGestureRecognizer) {
        final text = inline.text ?? '';
        if (text == 'example.com' && linkRecognizer == null) {
          linkRecognizer = inline.recognizer as TapGestureRecognizer;
        }
      }
      return true;
    });
    expect(linkRecognizer, isNotNull);
    linkRecognizer!.onTap!();

    expect(launched, ['https://example.com']);
  });

  testWidgets('input is refocused after sending a message', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);

    await tester.tap(textField);
    await tester.pump();
    final focusNode = tester.widget<TextField>(textField).focusNode;
    expect(focusNode?.hasFocus, isTrue);

    await tester.enterText(textField, 'hello');
    await tester.pump();

    final send = find.widgetWithIcon(IconButton, Icons.send);
    expect(send, findsOneWidget);
    await tester.tap(send);
    await tester.pumpAndSettle();

    final focusNodeAfter = tester.widget<TextField>(textField).focusNode;
    expect(state.sending, isFalse);
    expect(focusNodeAfter?.hasFocus, isTrue);
  });

  testWidgets('messages use full width on wide screens', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(role: 'assistant', content: 'A' * 2000, attachments: null),
          Message(role: 'user', content: 'B' * 2000, attachments: null),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final item = find.byType(ListView);
    expect(item, findsOneWidget);

    final firstMessage = find.ancestor(
      of: find.byType(CircleAvatar).first,
      matching: find.byType(Row),
    );
    expect(firstMessage, findsOneWidget);
    final size = tester.getSize(firstMessage);
    expect(size.width, closeTo(1920 - 48, 1));

    expect(tester.takeException(), isNull);
  });

  testWidgets('composer mode defaults to code and can be switched', (tester) async {
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
        messages: [],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('Code'), findsOneWidget);
    expect(find.text('Plan'), findsNothing);

    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();

    expect(state.composerMode, ComposerMode.plan);
    expect(find.text('Plan'), findsNWidgets(2));

    await tester.tap(find.text('Plan').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask').last);
    await tester.pumpAndSettle();

    expect(state.composerMode, ComposerMode.ask);
    expect(find.text('Ask'), findsNWidgets(2));
  });

  testWidgets('plan and ask modes show a badge', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      composerMode: ComposerMode.ask,
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
        messages: [],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('Ask'), findsNWidgets(2));
    expect(find.text('Code'), findsNothing);
  });

  testWidgets('shift+tab in composer cycles composer modes', (tester) async {
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
        messages: [],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();

    expect(state.composerMode, ComposerMode.code);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(state.composerMode, ComposerMode.ask);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(state.composerMode, ComposerMode.plan);
  });

  testWidgets('stop button is shown while sending', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
      sending: true,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final stop = find.widgetWithIcon(IconButton, Icons.stop);
    expect(stop, findsOneWidget);
  });

  testWidgets('stop button uses error color while sending', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
      sending: true,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final stop = find.widgetWithIcon(IconButton, Icons.stop);
    expect(stop, findsOneWidget);

    final button = tester.widget<IconButton>(stop);
    final theme = Theme.of(tester.element(stop));
    expect(button.style?.backgroundColor?.resolve({}), theme.colorScheme.error);
    expect(
      button.style?.foregroundColor?.resolve({}),
      theme.colorScheme.onError,
    );
  });

  testWidgets('send button keeps default style when not sending', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final send = find.widgetWithIcon(IconButton, Icons.send);
    expect(send, findsOneWidget);

    final button = tester.widget<IconButton>(send);
    expect(button.style, isNull);
  });

  testWidgets('elapsed time indicator shows when sending', (tester) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
      sending: true,
      startedAt: DateTime.now().toUtc().toIso8601String(),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pump();

    expect(find.byType(ElapsedTimeIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // The indicator shows a duration like "0s".
    final indicator = tester.widget<ElapsedTimeIndicator>(
      find.byType(ElapsedTimeIndicator),
    );
    expect(indicator.active, isTrue);
    expect(indicator.startedAt, isNotNull);
  });

  testWidgets('elapsed time indicator hidden when not sending', (tester) async {
    final state = AppState.test(
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
          title: 'Test thread',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
      sending: false,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.byType(ElapsedTimeIndicator), findsNothing);
  });
}
