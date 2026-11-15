import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/utils/preloader.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient extends BaseApiClient {
  String? url;

  @override
  bool get isNative => true;

  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  Future<String?> get serverUrl => Future.value(url);

  @override
  Future<String?> get token => Future.value('tok');

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
  }) => throw UnimplementedError();

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

  @override
  Future<void> setServerUrl(String serverUrl) async => url = serverUrl;

  @override
  Future<void> setToken(String token) => Future.value();

  @override
  Future<void> setUsername(String username) => Future.value();

  @override
  Future<void> clearCredentials() => Future.value();

  @override
  Future<void> init() => Future.value();
}

class _FakeApi extends ApiService {
  _FakeApi() : super(client: _FakeClient());

  _FakeClient get fakeClient => client as _FakeClient;

  List<List<Project>> projectPages = [];
  int listProjectsCalls = 0;
  Object? listProjectsError;

  Object? repoStatusError;

  final threadCompleters = <String, Completer<ThreadDetail>>{};
  List<Thread> listedThreads = [];
  bool manualThreadPages = false;
  int listThreadsCalls = 0;
  final threadPageFutures = <Completer<List<Thread>>>[];
  final threadProjects = <String, int>{};

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) {
    listProjectsCalls++;
    final error = listProjectsError;
    if (error != null) return Future.error(error);
    final page = (offset ?? 0) ~/ 50;
    if (page >= projectPages.length) return Future.value(const []);
    return Future.value(projectPages[page]);
  }

  @override
  Future<GitRepoInfo> gitRepoStatus(
    int projectId, {
    bool force = false,
    String? threadId,
  }) {
    final error = repoStatusError;
    if (error != null) return Future.error(error);
    return Future.value(
      GitRepoInfo(isRepo: true, branch: 'main', worktreePath: '/x'),
    );
  }

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) {
    return threadCompleters
        .putIfAbsent(id, () => Completer<ThreadDetail>())
        .future;
  }

  @override
  Future<Map<String, dynamic>> getThreadProject(String id) async => {
    'project_id': threadProjects[id] ?? 1,
  };

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) {
    if (manualThreadPages) {
      listThreadsCalls++;
      final c = Completer<List<Thread>>();
      threadPageFutures.add(c);
      return c.future;
    }
    return Future.value(listedThreads);
  }

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) async =>
      [];

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) async => {
    'status': 'idle',
  };

  @override
  Future<List<String>> getThreadRuns() async => [];

  @override
  Future<List<ModelInfo>> listModels({
    String? provider,
    String? nodeId,
  }) async => [];

  @override
  Future<List<DirEntry>> listFiles({
    String? path,
    int? projectId,
    String? threadId,
    String? nodeId,
    int? limit,
    int? offset,
  }) async => [];
}

Project _project(int id) =>
    Project(id: id, name: 'p$id', path: '/x/$id', createdAt: '', updatedAt: '');

Thread _thread(String id, {String? worktreePath, String envMode = 'local'}) =>
    Thread(
      id: id,
      title: 't$id',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      envMode: envMode,
      worktreePath: worktreePath,
      createdAt: '',
      updatedAt: '',
    );

ThreadDetail _detail(Thread thread) =>
    ThreadDetail(thread: thread, messages: const []);

void main() {
  group('project list', () {
    test(
      'loadProjects keeps the last known list on a transient error',
      () async {
        final api = _FakeApi();
        final state = AppState.test(api: api, projects: [_project(1)]);

        api.listProjectsError = ApiException('boom', 500);
        await state.loadProjects();

        expect(state.projects.map((p) => p.id), [1]);
        expect(state.globalError, isNotEmpty);
      },
    );

    test('loadMoreProjects advances past a fully duplicated page', () async {
      final api = _FakeApi();
      final page = [for (var i = 1; i <= 50; i++) _project(i)];
      // Page two returns the same rows: every entry is a duplicate.
      api.projectPages = [page, page];
      final state = AppState.test(api: api);

      await state.loadProjects();
      expect(state.projects, hasLength(50));
      expect(state.hasMoreProjects, isTrue);

      // The offset must track the server-side position (100), not the
      // number of fresh rows (0), or the next call would refetch the
      // duplicated page forever.
      await state.loadMoreProjects();
      expect(state.projects, hasLength(50));

      await state.loadMoreProjects();
      expect(state.hasMoreProjects, isFalse);
      expect(state.projects, hasLength(50));
    });
  });

  group('git repo info', () {
    test('transient errors keep the last known repo info', () async {
      final api = _FakeApi();
      final info = GitRepoInfo(isRepo: true, branch: 'main');
      final state = AppState.test(api: api, gitRepoInfo: {1: info});

      api.repoStatusError = ApiException('boom', 500);
      await state.loadGitRepoInfo(1);
      expect(state.gitRepoInfo(1), isNotNull);

      api.repoStatusError = ApiException('not a repo', 404);
      await state.loadGitRepoInfo(1);
      expect(state.gitRepoInfo(1), isNull);
    });
  });

  group('thread navigation', () {
    test('the last openThread wins over a slower earlier open', () async {
      final api = _FakeApi();
      api.listedThreads = [_thread('a'), _thread('b')];
      final state = AppState.test(
        api: api,
        projects: [_project(1)],
        threads: api.listedThreads,
      );

      final openA = state.openThread('a');
      final openB = state.openThread('b');

      api.threadCompleters['b']!.complete(_detail(_thread('b')));
      await openB;
      expect(state.activeThreadId, 'b');

      api.threadCompleters['a']!.complete(_detail(_thread('a')));
      await openA;
      expect(state.activeThreadId, 'b');
    });

    test(
      'a reset during an in-flight page load runs after it settles',
      () async {
        final api = _FakeApi()..manualThreadPages = true;
        final state = AppState.test(api: api, projects: [_project(1)]);

        final first = state.refreshThreadsAndGroups();
        expect(api.listThreadsCalls, 1);

        // The second refresh cannot zero the offset under the in-flight
        // page; it queues the reset instead.
        await state.refreshThreadsAndGroups();
        expect(api.listThreadsCalls, 1);

        api.threadPageFutures[0].complete([_thread('t1')]);
        await first;
        await Future<void>.delayed(Duration.zero);
        expect(api.listThreadsCalls, 2);

        api.threadPageFutures[1].complete([_thread('t2')]);
        await Future<void>.delayed(Duration.zero);
        expect(state.threads.map((t) => t.id), ['t2']);
      },
    );
  });

  group('files scope', () {
    test(
      'filesApiThreadId stays pinned to the thread the tree loaded under',
      () async {
        final api = _FakeApi();
        final t1 = _thread('t1', envMode: 'worktree', worktreePath: '/x/wt');
        final t2 = _thread('t2', envMode: 'worktree', worktreePath: '/x/wt');
        api.listedThreads = [t1, t2];
        api.threadProjects['t2'] = 2;
        api.threadCompleters['t2'] = Completer<ThreadDetail>()
          ..complete(_detail(t2));
        final state = AppState.test(
          api: api,
          projects: [_project(1), _project(2)],
          threads: api.listedThreads,
          activeProjectId: 1,
          activeThreadId: 't1',
          activeThreadDetail: _detail(t1),
        );

        await state.openFilesPanel();
        expect(state.filesApiThreadId, 't1');
        expect(state.filesApiProjectId, 1);

        await state.openThread('t2');
        expect(state.activeThreadId, 't2');
        expect(state.filesApiThreadId, 't1');
        expect(state.filesApiProjectId, 1);
      },
    );
  });

  group('terminal websocket uri', () {
    test('keeps a base-url subpath', () async {
      final api = _FakeApi();
      api.fakeClient.url = 'https://host.example/devinorium/';
      final uri = await api.terminalWebSocketUri('s1');
      expect(uri.scheme, 'wss');
      expect(uri.host, 'host.example');
      expect(uri.path, '/devinorium/api/terminal/sessions/s1/ws');
    });
  });

  group('preloader', () {
    test(
      'caches a null result instead of crashing coalesced callers',
      () async {
        final preloader = Preloader();
        var fetches = 0;
        Future<String?> fetch() async {
          fetches++;
          return null;
        }

        expect(await preloader.load<String?>('k', fetch), isNull);
        expect(await preloader.load<String?>('k', fetch), isNull);
        expect(fetches, 1);
      },
    );
  });
}
