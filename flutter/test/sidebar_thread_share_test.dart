import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  ) => throw UnimplementedError();
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
  }) => throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  final shareCalls = <String>[];
  final unshareCalls = <String>[];
  List<Thread> listThreadsResult = const [];
  Thread Function(String id)? onShare;
  Thread Function(String id)? onUnshare;

  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<Thread> shareThread(String id) async =>
      onShare!(id);

  @override
  Future<Thread> unshareThread(String id) async =>
      onUnshare!(id);

  @override
  Future<String> shareUrl(String shareId) async =>
      'https://srv.test/shared/$shareId';

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value(listThreadsResult);

  @override
  Future<List<Thread>> listThreadsForProject(
    int id, {
    int? limit,
    int? offset,
  }) =>
      Future.value(listThreadsResult);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value([]);

  @override
  Future<List<String>> getThreadRuns() => Future.value([]);
}

Thread _thread({String? shareId}) => Thread(
      id: 't1',
      title: 'feature work',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
      shareId: shareId,
    );

AppState _state(ApiService api, Thread thread) => AppState.test(
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

Widget _buildWithState(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: const Scaffold(
          drawer: Drawer(child: Sidebar()),
          body: SizedBox.shrink(),
        ),
      ),
    );

Future<void> _tapMoreVert(WidgetTester tester) async {
  final threadTile = find.ancestor(
    of: find.text('feature work'),
    matching: find.byType(ListTile),
  );
  await tester.tap(
    find.descendant(of: threadTile, matching: find.byIcon(Icons.more_vert)),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  await tester.pumpAndSettle();
  await tester.tap(find.text('p'));
  await tester.pumpAndSettle();
  await _tapMoreVert(tester);
}

void main() {
  String? clipboardText;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
          }
          return null;
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  setUp(() => clipboardText = null);

  testWidgets('Share menu item publishes the thread and copies the link', (
    tester,
  ) async {
    final api = _FakeApiService();
    final thread = _thread();
    api.listThreadsResult = [thread];
    api.onShare = (id) {
      api.shareCalls.add(id);
      return thread.copyWith(shareId: 'sh-abc');
    };
    final state = _state(api, thread);

    await tester.pumpWidget(_buildWithState(state));
    await _openMenu(tester);

    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Stop sharing'), findsNothing);
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();

    expect(api.shareCalls, ['t1']);
    expect(clipboardText, 'https://srv.test/shared/sh-abc');
    expect(state.threads.single.shareId, 'sh-abc');
    expect(find.text('Share link copied to clipboard'), findsOneWidget);
  });

  testWidgets('Shared thread menu copies the link and stops sharing', (
    tester,
  ) async {
    final api = _FakeApiService();
    final thread = _thread(shareId: 'sh-abc');
    api.listThreadsResult = [thread];
    api.onShare = (id) {
      api.shareCalls.add(id);
      return thread;
    };
    api.onUnshare = (id) {
      api.unshareCalls.add(id);
      return thread.copyWith(shareId: null);
    };
    final state = _state(api, thread);

    await tester.pumpWidget(_buildWithState(state));
    await _openMenu(tester);

    expect(find.text('Copy share link'), findsOneWidget);
    expect(find.text('Stop sharing'), findsOneWidget);
    expect(find.text('Share'), findsNothing);

    await tester.tap(find.text('Copy share link'));
    await tester.pumpAndSettle();
    expect(api.shareCalls, isEmpty,
        reason: 'copying an existing share must not re-publish');
    expect(clipboardText, 'https://srv.test/shared/sh-abc');

    await _tapMoreVert(tester);
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();

    expect(api.unshareCalls, ['t1']);
    expect(state.threads.single.shareId, isNull);
  });
}
