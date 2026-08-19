import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/ask_request_panel.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(true);

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

  String? lastAskThreadId;
  String? lastAskRequestId;
  Map<String, dynamic>? lastAskAnswers;

  @override
  Future<void> respondAsk(
    String threadId,
    String requestId,
    Map<String, dynamic>? answers,
  ) async {
    lastAskThreadId = threadId;
    lastAskRequestId = requestId;
    lastAskAnswers = answers;
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

AppState _stateWithAsk({
  ApiService? api,
  required AskRequest pendingAsk,
}) =>
    AppState.test(
      api: api,
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
          title: 'Test',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
      ),
      pendingAskRequest: pendingAsk,
      sending: false,
    );

void main() {
  group('AskRequestPanel', () {
    testWidgets('replaces the composer while an ask request is pending', (
      tester,
    ) async {
      final state = _stateWithAsk(
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'What would you like to work on today?',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Next task',
              fieldType: 'single_select',
              options: [
                AskOption(value: 'code', label: 'Code changes'),
                AskOption(value: 'new', label: 'New project'),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byType(AskRequestPanel), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.text('What would you like to work on today?'), findsOneWidget);
      expect(find.text('Next task'), findsOneWidget);
      expect(find.text('Code changes'), findsOneWidget);
      expect(find.text('New project'), findsOneWidget);
    });

    testWidgets('selects a single select option and sends the answer', (
      tester,
    ) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'What would you like to work on today?',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Next task',
              fieldType: 'single_select',
              required: true,
              options: [
                AskOption(value: 'code', label: 'Code changes'),
                AskOption(value: 'new', label: 'New project'),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Code changes'));
      await tester.pumpAndSettle();

      final send = find.widgetWithText(FilledButton, 'Send');
      expect(send, findsOneWidget);
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, 't1');
      expect(api.lastAskRequestId, 'a1');
      expect(api.lastAskAnswers, {'q1': 'code'});
      expect(state.pendingAskRequest, isNull);
      expect(find.byType(AskRequestPanel), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('cancel sends null and restores the composer', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Notes',
              fieldType: 'text',
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, 't1');
      expect(api.lastAskRequestId, 'a1');
      expect(api.lastAskAnswers, isNull);
      expect(state.pendingAskRequest, isNull);
      expect(find.byType(AskRequestPanel), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('validates required text fields before sending', (
      tester,
    ) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Your name',
              fieldType: 'text',
              required: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final send = find.widgetWithText(FilledButton, 'Send');
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, isNull);
      expect(find.text('Required'), findsOneWidget);
      expect(find.byType(AskRequestPanel), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, 't1');
      expect(api.lastAskAnswers, {'q1': 'Alice'});
      expect(state.pendingAskRequest, isNull);
    });

    testWidgets('handles multi select answers', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Pick tags',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Tags',
              fieldType: 'multi_select',
              options: [
                AskOption(value: 'x', label: 'X'),
                AskOption(value: 'y', label: 'Y'),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(
        find.ancestor(of: find.text('X'), matching: find.byType(FilterChip)),
      );
      await tester.tap(
        find.ancestor(of: find.text('Y'), matching: find.byType(FilterChip)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, {
        'q1': ['x', 'y'],
      });
    });

    testWidgets('validates and trims text answers', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Your name',
              fieldType: 'text',
              required: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final send = find.widgetWithText(FilledButton, 'Send');
      final field = find.byType(TextField);

      await tester.enterText(field, '   ');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, isNull);
      expect(find.text('Required'), findsOneWidget);

      await tester.enterText(field, '  Alice  ');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, 't1');
      expect(api.lastAskAnswers, {'q1': 'Alice'});
    });

    testWidgets('validates number fields and parses them', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Age',
              fieldType: 'number',
              required: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final send = find.widgetWithText(FilledButton, 'Send');
      final field = find.byType(TextField);

      await tester.enterText(field, '-');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, isNull);
      expect(find.text('Must be a valid number'), findsOneWidget);

      await tester.enterText(field, '42');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, 't1');
      expect(api.lastAskAnswers, {'q1': 42});
    });

    testWidgets('parses negative and decimal numbers', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a2',
          message: 'Need input',
          questions: [
            AskQuestion(id: 'neg', prompt: 'Neg', fieldType: 'number'),
            AskQuestion(id: 'dec', prompt: 'Dec', fieldType: 'number'),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      final send = find.widgetWithText(FilledButton, 'Send');

      await tester.enterText(fields.at(0), '-7');
      await tester.enterText(fields.at(1), '3.14');
      await tester.pumpAndSettle();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, {
        'neg': -7,
        'dec': 3.14,
      });
    });

    testWidgets('sends boolean answers', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Subscribe',
              fieldType: 'boolean',
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, {'q1': true});
    });

    testWidgets('sends the default boolean value', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Subscribe',
              fieldType: 'boolean',
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, {'q1': false});
    });

    testWidgets('multi select omits deselected options', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Pick tags',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Tags',
              fieldType: 'multi_select',
              options: [
                AskOption(value: 'x', label: 'X'),
                AskOption(value: 'y', label: 'Y'),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final xChip = find.ancestor(
        of: find.text('X'),
        matching: find.byType(FilterChip),
      );
      await tester.tap(xChip);
      await tester.pumpAndSettle();
      await tester.tap(xChip);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, isEmpty);
    });

    testWidgets('validates required single select', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Pick one',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Choice',
              fieldType: 'single_select',
              required: true,
              options: [
                AskOption(value: 'a', label: 'A'),
              ],
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();

      expect(api.lastAskThreadId, isNull);
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('cancel discards typed answers', (tester) async {
      final api = _FakeApiService();
      final state = _stateWithAsk(
        api: api,
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(
              id: 'q1',
              prompt: 'Your name',
              fieldType: 'text',
            ),
          ],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(api.lastAskAnswers, isNull);
      expect(state.pendingAskRequest, isNull);
      expect(find.byType(AskRequestPanel), findsNothing);
    });
  });
}
