import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
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
  Future<ThreadDetail> getThread(String id) => Future.value(
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
                  kind: 'execute',
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

    final markdown = find.byType(MarkdownBody);
    expect(markdown, findsOneWidget);
    expect(tester.widget<MarkdownBody>(markdown).data, 'hello done');

    expect(find.text('Run cmd'), findsOneWidget);
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
                  kind: 'execute',
                  status: 'completed',
                  command: 'echo hello',
                ),
              ),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-2',
                  title: 'Run another',
                  kind: 'execute',
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
                  kind: 'execute',
                  status: 'completed',
                  command: 'echo search',
                ),
              ),
              MessagePart.thinking(content: 'ok let me read'),
              MessagePart.toolCall(
                toolCall: ToolCallData(
                  id: 'tc-2',
                  title: 'read file',
                  kind: 'execute',
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
                  kind: 'execute',
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
}
