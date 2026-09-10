import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

class _ThrowingClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(false);
  @override
  Future<void> clearCredentials() => Future.value();
  @override
  Future<void> init() => Future.value();
  @override
  bool get isNative => true;
  @override
  Future<String?> get serverUrl => Future.value(null);
  @override
  Future<String?> get token => Future.value(null);
  @override
  Future<void> setServerUrl(String serverUrl) => Future.value();
  @override
  Future<void> setToken(String token) => Future.value();
  @override
  Future<void> setUsername(String username) => Future.value();
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
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
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
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  final linkedMrCalls = <(String threadId, String? url)>[];
  List<Thread> listThreadsResult = const [];
  List<Thread> listThreadsForProjectResult = const [];
  MergeRequestLink? findMergeRequestByIidResult;

  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<void> setThreadLinkedMr(String id, String? url) async {
    linkedMrCalls.add((id, url));
  }

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value(listThreadsResult);

  @override
  Future<List<Thread>> listThreadsForProject(
    int id, {
    int? limit,
    int? offset,
  }) =>
      Future.value(listThreadsForProjectResult);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value([]);

  @override
  Future<List<String>> getThreadRuns() => Future.value([]);

  @override
  Future<GitRepoInfo> gitRepoStatus(int projectId, {bool force = false}) =>
      Future.value(GitRepoInfo());

  @override
  Future<MergeRequestLink?> findMergeRequestByIid(
    int projectId,
    int iid,
  ) async =>
      findMergeRequestByIidResult;
}

Widget _buildWithState(AppState state) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    home: const Scaffold(
      drawer: Drawer(child: Sidebar()),
      body: SizedBox.shrink(),
    ),
  ),
);

Future<void> _openDrawer(WidgetTester tester) async {
  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
  scaffold.openDrawer();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
  });

  testWidgets('Thread tile menu links a merge request', (tester) async {
    final api = _FakeApiService();
    final thread = Thread(
      id: 't1',
      title: 'feature work',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
    );
    final linkedRef = LinkedMergeRequestRef.tryParse(
      'https://gitlab.example.com/g/p/-/merge_requests/5',
    );
    api.listThreadsResult = [thread];
    api.listThreadsForProjectResult = [thread];
    final state = AppState.test(
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
      projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
      threads: [thread],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('p'));
    await tester.pumpAndSettle();

    final threadTile = find.ancestor(
      of: find.text('feature work'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: threadTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Link merge request'), findsOneWidget);
    await tester.tap(find.text('Link merge request'));
    await tester.pumpAndSettle();

    final urlField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(urlField, findsOneWidget);
    await tester.enterText(
      urlField,
      'https://gitlab.example.com/g/p/-/merge_requests/5',
    );

    api.listThreadsResult = [
      if (linkedRef != null) thread.copyWith(linkedMr: linkedRef) else thread,
    ];

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      api.linkedMrCalls,
      [(thread.id, 'https://gitlab.example.com/g/p/-/merge_requests/5')],
    );
    expect(find.text('!5'), findsOneWidget);
  });

  testWidgets('Thread tile menu unlinks a merge request', (tester) async {
    final api = _FakeApiService();
    final thread = Thread(
      id: 't1',
      title: 'feature work',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
      linkedMr: const LinkedMergeRequestRef(
        hostname: 'gitlab.example.com',
        projectPath: 'g/p',
        iid: 5,
        webUrl: 'https://gitlab.example.com/g/p/-/merge_requests/5',
      ),
    );
    api.listThreadsResult = [thread];
    api.listThreadsForProjectResult = [thread];
    final state = AppState.test(
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
      projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
      threads: [thread],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('p'));
    await tester.pumpAndSettle();

    final threadTile = find.ancestor(
      of: find.text('feature work'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: threadTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unlink merge request'), findsOneWidget);
    expect(find.text('Link merge request'), findsNothing);

    api.listThreadsResult = [thread.copyWith(linkedMrOrNull: null)];
    await tester.tap(find.text('Unlink merge request'));
    await tester.pumpAndSettle();

    expect(api.linkedMrCalls, [(thread.id, null)]);
    expect(find.text('!5'), findsNothing);
  });

  testWidgets('Badge reflects live merge request state for active thread', (
    tester,
  ) async {
    final api = _FakeApiService();
    api.findMergeRequestByIidResult = const MergeRequestLink(
      iid: 5,
      title: 'Fix everything',
      state: 'merged',
      sourceBranch: 'fix',
      targetBranch: 'main',
      webUrl: 'https://gitlab.example.com/g/p/-/merge_requests/5',
    );
    final thread = Thread(
      id: 't1',
      title: 'feature work',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
      linkedMr: const LinkedMergeRequestRef(
        hostname: 'gitlab.example.com',
        projectPath: 'g/p',
        iid: 5,
        webUrl: 'https://gitlab.example.com/g/p/-/merge_requests/5',
      ),
    );
    final state = AppState.test(
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
      projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
      threads: [thread],
      activeProjectId: 1,
      activeThreadId: 't1',
    );

    await state.loadLinkedMergeRequestByIid(1, thread.linkedMr!);
    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('!5'), findsOneWidget);

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.ancestor(of: find.text('!5'), matching: find.byType(InkWell)).first,
        matching: find.byIcon(Icons.merge),
      ),
    );
    final theme = Theme.of(tester.element(find.text('!5')));
    expect(icon.color, theme.colorScheme.tertiary);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('!5'), matching: find.byType(Tooltip)).first,
    );
    expect(tooltip.message, contains('Fix everything'));
    expect(tooltip.message, contains('fix → main'));
  });
}
