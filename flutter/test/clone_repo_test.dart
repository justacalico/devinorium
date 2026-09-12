import 'dart:async';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
  }) => throw UnimplementedError();
}

class _PendingCloneApi extends _FakeApiService {
  final Completer<String> completer;

  _PendingCloneApi(this.completer);

  @override
  Future<String> cloneRepo(String url) {
    _cloneRepoCalls.add(url);
    return completer.future;
  }
}

class _FakeApiService extends ApiService {
  final _cloneRepoCalls = <String>[];
  final _cloneRepoResults = <String, String>{};
  final _cloneRepoThrows = <String, Object>{};
  var _listProjectsReturns = <Project>[];

  _FakeApiService() : super(client: _ThrowingClient());

  void setCloneResult(String url, String path) {
    _cloneRepoResults[url] = path;
  }

  void setCloneError(String url, Object error) {
    _cloneRepoThrows[url] = error;
  }

  set listProjectsReturns(List<Project> value) {
    _listProjectsReturns = value;
  }

  List<String> get cloneRepoCalls => List.unmodifiable(_cloneRepoCalls);

  @override
  Future<String> cloneRepo(String url) {
    _cloneRepoCalls.add(url);
    if (_cloneRepoThrows.containsKey(url)) {
      throw _cloneRepoThrows[url]!;
    }
    return Future.value(_cloneRepoResults[url] ?? '/clone/$url');
  }

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) {
    return Future.value(_listProjectsReturns);
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const DialogLayer(),
  ),
);

Finder _findTextContaining(String text) =>
    find.byWidgetPredicate((w) => w is Text && w.data?.contains(text) == true);

void main() {
  testWidgets('clone dialog submits and shows result', (tester) async {
    final api = _FakeApiService();
    const url = 'https://gitlab.com/owner/repo.git';
    const path = '/root/gitlab/owner/repo';
    api.setCloneResult(url, path);
    api.listProjectsReturns = [
      Project(
        id: 1,
        name: 'owner/repo',
        path: path,
        pinned: false,
        createdAt: '',
        updatedAt: '',
      ),
    ];
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('Clone repository'), findsOneWidget);
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    expect(api.cloneRepoCalls, contains(url));
    expect(state.cloneRepoResult, path);
    expect(find.text(path), findsOneWidget);
  });

  testWidgets('clone dialog renders 400 error', (tester) async {
    final api = _FakeApiService();
    const url = 'https://gitlab.com/repo.git';
    api.setCloneError(url, Exception('HTTP 400: remote URL has no owner'));
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    expect(state.globalError, contains('400'));
    expect(_findTextContaining('HTTP 400'), findsOneWidget);
    expect(_findTextContaining('no owner'), findsOneWidget);
  });

  testWidgets('clone dialog renders 409 conflict', (tester) async {
    final api = _FakeApiService();
    const url = 'https://gitlab.com/owner/repo.git';
    api.setCloneError(url, Exception('HTTP 409: clone target already exists'));
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    expect(state.globalError, contains('409'));
    expect(_findTextContaining('409'), findsOneWidget);
    expect(_findTextContaining('already exists'), findsOneWidget);
  });

  testWidgets('clone dialog renders 502 clone failure', (tester) async {
    final api = _FakeApiService();
    const url = 'git://127.0.0.1:1/owner/repo.git';
    api.setCloneError(url, Exception('HTTP 502: timeout'));
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    expect(state.globalError, contains('502'));
    expect(_findTextContaining('502'), findsOneWidget);
  });

  testWidgets('a clone finishing after the dialog was abandoned does not leak its result',
      (tester) async {
    final completer = Completer<String>();
    final api = _PendingCloneApi(completer);
    const url = 'https://gitlab.com/owner/repo.git';
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pump();

    expect(state.cloningRepo, true);

    // Back to the picker, then into the clone dialog again.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone repository'));
    await tester.pumpAndSettle();

    completer.complete('/clone/$url');
    await tester.pumpAndSettle();

    // The abandoned clone must not overwrite the reopened dialog's state.
    expect(state.cloneRepoResult, isNull);
    expect(state.cloningRepo, false);
    expect(find.text('/clone/$url'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Remote URL',
      ),
      findsOneWidget,
    );
  });

  testWidgets('open project button selects the cloned project', (tester) async {
    final api = _FakeApiService();
    const url = 'https://gitlab.com/owner/repo.git';
    const path = '/root/gitlab/owner/repo';
    api.setCloneResult(url, path);
    api.listProjectsReturns = [
      Project(
        id: 1,
        name: 'owner/repo',
        path: path,
        pinned: false,
        createdAt: '',
        updatedAt: '',
      ),
    ];
    final state = AppState.test(api: api, dialog: DialogKind.cloneRepo);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open project'));
    await tester.pumpAndSettle();

    expect(state.activeProjectId, 1);
    expect(state.dialog, DialogKind.none);
  });
}
