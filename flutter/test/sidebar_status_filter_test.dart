import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/foundation.dart';
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
  Stream<SseEvent> postStream({
    required String path,
    Map<String, String> fields = const {},
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) =>
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
  ) =>
      throw UnimplementedError();
  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
    List<int> machineIds = const [],
  }) =>
      throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<bool> checkHealth() => Future.value(true);

  @override
  Future<List<String>> getThreadRuns() => Future.value([]);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value([]);
}

User _user() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

Project _project(int id) =>
    Project(id: id, name: 'p$id', path: '/x$id', createdAt: '', updatedAt: '');

Thread _thread(String id, int projectId, {String? lastMessageRole}) => Thread(
  id: id,
  title: 'Thread $id',
  projectId: projectId,
  model: '',
  permissionMode: 'normal',
  createdAt: '',
  updatedAt: '',
  lastMessageRole: lastMessageRole,
);

AppState _state() => AppState.test(
  api: _FakeApiService(),
  user: _user(),
  projects: [_project(1), _project(2)],
  threads: [
    _thread('run', 1),
    _thread('done', 1, lastMessageRole: 'assistant'),
    _thread('fail', 1),
    _thread('other', 2, lastMessageRole: 'assistant'),
  ],
  activeProjectId: 1,
);

SseEvent _runStatus(String tid, String status) => SseEvent(
  'run_status',
  jsonEncode({
    'thread_id': tid,
    'run_id': 'r-$tid',
    'status': status,
    'updated_at': 'now',
  }),
);

Widget _buildWithState(AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(
        home: Scaffold(
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

Future<void> _selectFilter(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(const Key('status_filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('status_filter_$key')));
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

  testWidgets('Status filter defaults to all statuses', (tester) async {
    final state = _state();
    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.byKey(const Key('status_filter')), findsOneWidget);
    expect(find.text('All statuses'), findsOneWidget);

    await tester.tap(find.text('p1'));
    await tester.pumpAndSettle();

    expect(find.text('Thread run'), findsOneWidget);
    expect(find.text('Thread done'), findsOneWidget);
    expect(find.text('Thread fail'), findsOneWidget);
  });

  testWidgets('Working filter keeps only live runs', (tester) async {
    final state = _state();
    state.handleRunEventForTest(_runStatus('run', 'running'));
    state.handleRunEventForTest(_runStatus('fail', 'failed'));

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await _selectFilter(tester, 'running');

    expect(find.text('Thread run'), findsOneWidget);
    expect(find.text('Thread done'), findsNothing);
    expect(find.text('Thread fail'), findsNothing);
    // Project 2 has no running threads, so it drops out entirely.
    expect(find.text('p2'), findsNothing);
  });

  testWidgets('Done filter keeps completed threads across projects', (
    tester,
  ) async {
    final state = _state();
    state.handleRunEventForTest(_runStatus('run', 'running'));
    state.handleRunEventForTest(_runStatus('fail', 'failed'));

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await _selectFilter(tester, 'done');

    expect(find.text('Thread done'), findsOneWidget);
    expect(find.text('Thread other'), findsOneWidget);
    expect(find.text('Thread run'), findsNothing);
    expect(find.text('Thread fail'), findsNothing);
  });

  testWidgets('Failed filter keeps only failed threads', (tester) async {
    final state = _state();
    state.handleRunEventForTest(_runStatus('run', 'running'));
    state.handleRunEventForTest(_runStatus('fail', 'failed'));

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await _selectFilter(tester, 'failed');

    expect(find.text('Thread fail'), findsOneWidget);
    expect(find.text('Thread run'), findsNothing);
    expect(find.text('Thread done'), findsNothing);
    expect(find.text('Thread other'), findsNothing);
  });

  testWidgets('Filtered list follows run status changes', (tester) async {
    final state = _state();
    state.handleRunEventForTest(_runStatus('run', 'running'));

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await _selectFilter(tester, 'running');

    expect(find.text('Thread run'), findsOneWidget);

    // The run finishing drops the thread out of the live filter.
    state.handleRunEventForTest(_runStatus('run', 'completed'));
    await tester.pumpAndSettle();

    expect(find.text('Thread run'), findsNothing);
    expect(find.text('No threads found.'), findsOneWidget);
  });

  testWidgets('Returning to all statuses shows every thread again', (
    tester,
  ) async {
    final state = _state();
    state.handleRunEventForTest(_runStatus('run', 'running'));

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await _selectFilter(tester, 'running');
    expect(find.text('Thread done'), findsNothing);

    await _selectFilter(tester, 'all');
    await tester.tap(find.text('p1'));
    await tester.pumpAndSettle();

    expect(find.text('Thread run'), findsOneWidget);
    expect(find.text('Thread done'), findsOneWidget);
    expect(find.text('Thread fail'), findsOneWidget);
  });
}
