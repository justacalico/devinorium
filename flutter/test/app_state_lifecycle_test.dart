import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingApiService extends ApiService {
  _RecordingApiService({
    this.checkHealthResults = const [true],
    this.serverVersionResult,
    this.getThreadRunResult = const {'status': 'idle'},
  }) : super(client: _NoOpClient());

  final List<bool> checkHealthResults;
  final String? serverVersionResult;
  final Map<String, dynamic> getThreadRunResult;

  var checkHealthCalls = 0;
  var serverVersionCalls = 0;
  var getThreadRunCalls = 0;
  var watchThreadEventsCalls = 0;
  var getThreadRunsCalls = 0;

  @override
  Future<bool> checkHealth() async {
    checkHealthCalls++;
    return checkHealthResults[checkHealthCalls - 1];
  }

  @override
  Future<String?> serverVersion() async {
    serverVersionCalls++;
    return serverVersionResult;
  }

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) async {
    getThreadRunCalls++;
    return getThreadRunResult;
  }

  @override
  Stream<SseEvent> watchThreadEvents(String id) {
    watchThreadEventsCalls++;
    return Stream<SseEvent>.empty();
  }

  @override
  Future<List<String>> getThreadRuns() async {
    getThreadRunsCalls++;
    return [];
  }

  @override
  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async {
    return const MessagePage();
  }
}

class _NoOpClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  Future<Map<String, dynamic>> get(String path) => Future.value({});

  @override
  Future<List<Map<String, dynamic>>> getList(String path) => Future.value([]);

  @override
  Stream<SseEvent> getStream({required String path}) => Stream.empty();

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      Future.value({});

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      Future.value({});

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      Future.value({});

  @override
  Future<Map<String, dynamic>> delete(String path) => Future.value({});

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      Future.value({});

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) =>
      Future.value({});

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
  }) =>
      Stream.empty();

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
  bool get isNative => false;

  @override
  Future<String?> get serverUrl => Future.value(null);

  @override
  Future<String?> get token => Future.value(null);
}

User _testUser() => User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      isOwner: true,
      providerId: 'devin-cli',
      providerCommand: 'devin',
    );

Thread _testThread() => Thread(
      id: 'a',
      title: 't',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
    );

ThreadDetail _testDetail() => ThreadDetail(
      thread: _testThread(),
      totalMessages: 0,
    );

AppState _runningState(_RecordingApiService api) => AppState.test(
      api: api,
      user: _testUser(),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [_testThread()],
      activeProjectId: 1,
      activeThreadId: 'a',
      activeThreadDetail: _testDetail(),
      sending: true,
    );

void main() {
  group('LifecycleStore', () {
    test('handleAppResumed checks connection and resumes running thread', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [true],
          serverVersionResult: '0.1',
          getThreadRunResult: const {'status': 'running'},
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);

        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 300));

        expect(api.checkHealthCalls, 1);
        expect(api.serverVersionCalls, 1);
        expect(api.getThreadRunsCalls, 1);
        expect(api.getThreadRunCalls, 1);
        expect(api.watchThreadEventsCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });

    test('handleAppResumed skips resume while disconnected', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [false],
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);

        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 300));

        expect(api.checkHealthCalls, 1);
        expect(api.serverVersionCalls, 0);
        expect(api.getThreadRunsCalls, 0);
        expect(api.getThreadRunCalls, 0);
        expect(api.watchThreadEventsCalls, 0);
        expect(state.connectionStatus, ConnectionStatus.disconnected);
      });
    });

    test('handleAppResumed does nothing outside app view', () {
      fakeAsync((async) {
        final api = _RecordingApiService();
        final state = _runningState(api);
        addTearDown(state.dispose);

        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 300));

        expect(api.checkHealthCalls, 0);
      });
    });

    test('handleAppResumed resumes once the connection comes back', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [false, true],
          serverVersionResult: '0.1',
          getThreadRunResult: const {'status': 'running'},
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);

        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 300));
        expect(api.checkHealthCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.disconnected);

        async.elapse(const Duration(seconds: 2));
        expect(api.checkHealthCalls, 2);
        expect(api.getThreadRunCalls, 1);
        expect(api.watchThreadEventsCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });

    test('handleAppResumed resumes when health checks are already running', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [true, true],
          serverVersionResult: '0.1',
          getThreadRunResult: const {'status': 'running'},
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);

        state.startHealthChecks();
        async.elapse(Duration.zero);
        expect(api.checkHealthCalls, 1);

        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 300));
        expect(api.checkHealthCalls, 2);
        expect(api.getThreadRunCalls, 1);
        expect(api.watchThreadEventsCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });

    test('handleAppResumed debounces rapid lifecycle changes', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [true],
          serverVersionResult: '0.1',
          getThreadRunResult: const {'status': 'running'},
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);

        state.handleAppResumed();
        state.handleAppResumed();
        state.handleAppResumed();
        async.elapse(const Duration(milliseconds: 100));
        expect(api.checkHealthCalls, 0);
        async.elapse(const Duration(milliseconds: 200));

        expect(api.checkHealthCalls, 1);
        expect(api.getThreadRunCalls, 1);
      });
    });
  });

  group('HealthCheckStore', () {
    test('checkConnection retries quickly after a failure', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [false, true],
          serverVersionResult: '0.1',
        );
        final state = AppState.test(api: api);
        addTearDown(state.dispose);
        state.setView(AppView.app);
        state.startHealthChecks();

        async.elapse(Duration.zero);
        expect(api.checkHealthCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.disconnected);

        async.elapse(const Duration(seconds: 2));
        expect(api.checkHealthCalls, 2);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });

    test('checkConnection returns the in-flight future', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [true],
          serverVersionResult: '0.1',
        );
        final state = AppState.test(api: api);
        addTearDown(state.dispose);

        unawaited(state.checkConnection());
        unawaited(state.checkConnection());
        async.elapse(Duration.zero);

        expect(api.checkHealthCalls, 1);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });

    test('periodic health checks do not resume threads by themselves', () {
      fakeAsync((async) {
        final api = _RecordingApiService(
          checkHealthResults: const [true, true],
          serverVersionResult: '0.1',
        );
        final state = _runningState(api);
        addTearDown(state.dispose);
        state.setView(AppView.app);
        state.startHealthChecks();

        async.elapse(const Duration(seconds: 30));
        expect(api.checkHealthCalls, 2);
        expect(api.getThreadRunCalls, 0);
        expect(api.watchThreadEventsCalls, 0);
        expect(state.connectionStatus, ConnectionStatus.connected);
      });
    });
  });
}
