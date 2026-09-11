import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ApiClient _clientFor(List<http.Response> responses) {
  var index = 0;
  return ApiClient.withClient(
    MockClient((req) async {
      if (index >= responses.length) {
        return _json(404, {'error': 'unexpected request to ${req.url.path}'});
      }
      return responses[index++];
    }),
  );
}

ApiService _serviceFor(ApiClient client) => ApiService(client: client);

class _StreamApiService extends ApiService {
  _StreamApiService(ApiClient client) : super(client: client);

  final controller = StreamController<SseEvent>();

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
  }) => controller.stream;
}

Map<String, Object> _fileJson(String path, String text) => {
      'path': path,
      'mime': 'text/plain',
      'size': text.length,
      'base64': '',
      'text': text,
      'sha256': 'sha-$text',
    };

ThreadDetail _threadDetail({String? worktreePath, String envMode = 'local'}) =>
    ThreadDetail(
      thread: Thread(
        id: 't1',
        title: 'Test',
        projectId: 1,
        model: 'm1',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
        worktreePath: worktreePath,
        envMode: envMode,
      ),
      messages: const [],
    );

void main() {
  final project = Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '');

  group('AppMode', () {
    test('defaults to agents', () {
      final state = AppState.test();
      expect(state.appMode, AppMode.agents);
    });

    test('can switch to editor', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.appMode, AppMode.editor);
    });

    test('switching to editor opens files panel and shows threads page', () {
      final state = AppState.test();
      state.setPage(MainPage.settings);
      state.setAppMode(AppMode.editor);

      expect(state.appMode, AppMode.editor);
      expect(state.page, MainPage.threads);
      expect(state.filesPanelOpen, isTrue);
    });

    test('switching to agents closes files panel and shows threads page', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);

      state.setPage(MainPage.settings);
      state.setAppMode(AppMode.agents);

      expect(state.appMode, AppMode.agents);
      expect(state.page, MainPage.threads);
      expect(state.filesPanelOpen, isFalse);
    });

    test('switching to the same mode is a no-op', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);

      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);
    });

    test('no-op mode switch preserves page and panel state', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      state.setPage(MainPage.settings);

      state.setAppMode(AppMode.editor);

      expect(state.appMode, AppMode.editor);
      expect(state.page, MainPage.settings);
      expect(state.filesPanelOpen, isTrue);
    });
  });

  group('Editor store', () {
    test('openEditorFile adds a tab and loads content', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );

      await state.openEditorFile('a.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, 'a.txt');
      final tab = state.activeEditorTab!;
      expect(tab.loading, isFalse);
      expect(tab.text, 'hello');
      expect(tab.dirty, isFalse);
      expect(tab.content?.sha256, 'abc');
    });

    test('setEditorTabText tracks dirty state', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      final updated = state.activeEditorTab!;
      expect(updated.dirty, isTrue);
      expect(state.hasDirtyEditorTabs, isTrue);
    });

    test('saveEditorTab writes and clears dirty', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 7,
          'base64': '',
          'text': 'changed',
          'sha256': 'def',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.dirty, isFalse);
      expect(saved.content?.sha256, 'def');
      expect(saved.text, 'changed');
    });

    test('saveEditorTab handles conflict', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(409, {
          'error': 'conflict',
          'current': {
            'path': '/x/a.txt',
            'mime': 'text/plain',
            'size': 4,
            'base64': '',
            'text': 'disk',
            'sha256': 'xyz',
          },
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.error, isNotNull);
      expect(saved.content?.sha256, 'xyz');
    });

    test('saveEditorTab keeps user text and recomputes dirty', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 6,
          'base64': '',
          'text': 'server',
          'sha256': 'def',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'user');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.text, 'user');
      expect(saved.content?.text, 'server');
      expect(saved.dirty, isTrue);
    });

    test('saveEditorTab skips binary files', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.bin',
          'mime': 'application/octet-stream',
          'size': 4,
          'base64': 'AAAAAA==',
          'text': null,
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.bin');

      // Should not try to write and consume another response.
      await state.saveEditorTab('a.bin');

      final saved = state.activeEditorTab!;
      expect(saved.dirty, isFalse);
      expect(saved.content?.text, isNull);
    });

    test('closeAllEditorTabs clears tabs', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');

      state.closeAllEditorTabs();

      expect(state.editorTabs, isEmpty);
      expect(state.activeEditorPath, isNull);
    });

    test('closeEditorTab switches active to another tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      state.setEditorTabText('/x/a.txt', 'changed');
      await state.openEditorFile('/x/b.txt');

      expect(state.editorTabs.length, 2);
      expect(state.activeEditorPath, '/x/b.txt');
      state.closeEditorTab('/x/b.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, '/x/a.txt');
    });

    test('openEditorFile replaces an unmodified preview tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      await state.openEditorFile('/x/b.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, '/x/b.txt');
    });

    test('openEditorFileNewTab keeps an unmodified preview tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      await state.openEditorFileNewTab('/x/b.txt');

      expect(state.editorTabs.length, 2);
      expect(state.activeEditorPath, '/x/b.txt');
    });

    test('openEditorFile resolves paths under the active worktree', () async {
      String? requestedPath;
      String? requestedThread;
      final client = ApiClient.withClient(
        MockClient((req) async {
          requestedPath = req.url.queryParameters['path'];
          requestedThread = req.url.queryParameters['thread_id'];
          return _json(200, _fileJson('/wt/a.txt', 'x'));
        }),
      );
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(
          worktreePath: '/wt',
          envMode: 'worktree',
        ),
      );
      state.setFilesEntries(const []);

      await state.openEditorFile('a.txt');

      // The tab key is the absolute worktree path so it cannot be confused
      // with a project file after a scope switch.
      expect(state.editorTabs.map((t) => t.path), ['/wt/a.txt']);
      expect(state.activeEditorPath, '/wt/a.txt');
      expect(requestedPath, '/wt/a.txt');
      // Absolute paths resolve on their own; no thread scoping needed.
      expect(requestedThread, isNull);
      expect(state.activeEditorTab?.projectId, 1);
    });

    test('local-mode thread keeps paths project-relative', () async {
      String? requestedPath;
      final client = ApiClient.withClient(
        MockClient((req) async {
          requestedPath = req.url.queryParameters['path'];
          return _json(200, _fileJson('a.txt', 'x'));
        }),
      );
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(worktreePath: '/wt'),
      );

      await state.openEditorFile('a.txt');

      expect(state.activeEditorPath, 'a.txt');
      expect(requestedPath, 'a.txt');
    });

    test('saveEditorTab writes to the worktree path', () async {
      String? writtenPath;
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.method == 'PUT') {
            writtenPath =
                (jsonDecode(req.body) as Map<String, dynamic>)['path']
                    as String?;
            return _json(200, _fileJson('/wt/a.txt', 'new'));
          }
          return _json(200, _fileJson('/wt/a.txt', 'old'));
        }),
      );
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(
          worktreePath: '/wt',
          envMode: 'worktree',
        ),
      );
      state.setFilesEntries(const []);
      await state.openEditorFile('a.txt');
      state.setEditorTabText('/wt/a.txt', 'new');

      await state.saveEditorTab('/wt/a.txt');

      expect(writtenPath, '/wt/a.txt');
      expect(state.activeEditorTab?.dirty, isFalse);
    });

    test('deleteFile closes worktree-scoped tabs', () async {
      final client = _clientFor([
        _json(200, _fileJson('/wt/a.txt', 'x')),
        _json(200, {}),
        _json(200, []),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(
          worktreePath: '/wt',
          envMode: 'worktree',
        ),
      );
      state.setFilesEntries(const []);
      await state.openEditorFileNewTab('a.txt');
      expect(state.editorTabs.length, 1);

      await state.deleteFile('a.txt');

      expect(state.editorTabs, isEmpty);
    });

    test('toggle panels updates state', () {
      final state = AppState.test();
      expect(state.agentPanelOpen, isTrue);
      expect(state.agentPanelUserSet, isFalse);
      expect(state.editorTerminalOpen, isFalse);
      state.setAgentPanelOpen(false);
      state.setEditorTerminalOpen(true);
      expect(state.agentPanelOpen, isFalse);
      expect(state.agentPanelUserSet, isTrue);
      expect(state.editorTerminalOpen, isTrue);
    });
  });

  group('agent edited files', () {
    String editPart(String id, List<String> files) =>
        '{"type":"tool_call","id":"$id","title":"Edit",'
        '"kind":"edit","status":"in_progress",'
        '"changed_files":[${files.map((f) => '"$f"').join(',')}]}';

    test('editor mode opens and focuses the edited file', () async {
      final api = _StreamApiService(
        _clientFor([_json(200, {}), _json(200, _fileJson('src/a.rs', 'new'))]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(),
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.sendMessage();

      api.controller.add(
        SseEvent('part', editPart('tc1', ['src/a.rs']), id: '1'),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.map((t) => t.path), ['src/a.rs']);
      expect(state.activeEditorPath, 'src/a.rs');
      expect(state.activeEditorTab?.text, 'new');
    });

    test('agents mode does not open tabs', () async {
      final api = _StreamApiService(_clientFor([_json(200, {})]));
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(),
        composerText: 'go',
      );
      await state.sendMessage();

      api.controller.add(
        SseEvent('part', editPart('tc1', ['src/a.rs']), id: '1'),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs, isEmpty);
    });

    test('absolute paths under the project root become relative', () async {
      final api = _StreamApiService(
        _clientFor([_json(200, {}), _json(200, _fileJson('lib/b.dart', 'x'))]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(),
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.sendMessage();

      api.controller.add(
        SseEvent('part', editPart('tc1', ['/x/lib/b.dart']), id: '1'),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.map((t) => t.path), ['lib/b.dart']);
      expect(state.activeEditorPath, 'lib/b.dart');
    });

    test('thread list entry supplies the worktree when detail unloads', () async {
      final api = _StreamApiService(
        _clientFor([_json(200, _fileJson('/wt/c.rs', 'x'))]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadId: 't1',
        // No activeThreadDetail: the edit event can arrive while the store
        // detail is still loading; the sidebar list entry is the fallback.
        threads: [
          Thread(
            id: 't1',
            title: 't',
            projectId: 1,
            model: 'm',
            permissionMode: 'normal',
            envMode: 'worktree',
            worktreePath: '/wt',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.sendMessage();

      api.controller.add(
        SseEvent('part', editPart('tc1', ['c.rs']), id: '1'),
      );
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.map((t) => t.path), ['/wt/c.rs']);
      expect(state.activeEditorPath, '/wt/c.rs');
    });

    test('relative paths resolve against the thread worktree', () async {
      final api = _StreamApiService(
        _clientFor([_json(200, {}), _json(200, _fileJson('/wt/c.rs', 'x'))]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(
          worktreePath: '/wt',
          envMode: 'worktree',
        ),
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.sendMessage();

      api.controller.add(SseEvent('part', editPart('tc1', ['c.rs']), id: '1'));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.map((t) => t.path), ['/wt/c.rs']);
      expect(state.activeEditorPath, '/wt/c.rs');
    });

    test('an already open tab is focused and reloaded', () async {
      final api = _StreamApiService(
        _clientFor([
          _json(200, _fileJson('a.txt', 'old')),
          _json(200, {}),
          _json(200, _fileJson('a.txt', 'new')),
        ]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(),
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.openEditorFileNewTab('a.txt');
      await state.sendMessage();

      api.controller.add(SseEvent('part', editPart('tc1', ['a.txt']), id: '1'));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, 'a.txt');
      expect(state.activeEditorTab?.text, 'new');
    });

    test('a dirty tab is focused but not reloaded', () async {
      final api = _StreamApiService(
        _clientFor([_json(200, _fileJson('a.txt', 'old')), _json(200, {})]),
      );
      final state = AppState.test(
        api: api,
        projects: [project],
        activeProjectId: 1,
        activeThreadDetail: _threadDetail(),
        composerText: 'go',
      );
      state.setAppMode(AppMode.editor);
      await state.openEditorFileNewTab('a.txt');
      state.setEditorTabText('a.txt', 'user');
      await state.sendMessage();

      api.controller.add(SseEvent('part', editPart('tc1', ['a.txt']), id: '1'));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, 'a.txt');
      expect(state.activeEditorTab?.text, 'user');
      expect(state.activeEditorTab?.dirty, isTrue);
      // No reload ran: the on-disk snapshot is still the first read.
      expect(state.activeEditorTab?.content?.sha256, 'sha-old');
    });

    test('reload keeps edits made while the read is in flight', () async {
      final completer = Completer<http.Response>();
      var call = 0;
      final client = ApiClient.withClient(
        MockClient((req) {
          call++;
          if (call == 1) {
            return Future.value(_json(200, _fileJson('a.txt', 'old')));
          }
          return completer.future;
        }),
      );
      final state = AppState.test(
        api: ApiService(client: client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFileNewTab('a.txt');

      final reload = state.reloadEditorTab('a.txt');
      state.setEditorTabText('a.txt', 'user');
      completer.complete(_json(200, _fileJson('a.txt', 'disk')));
      await reload;

      final tab = state.activeEditorTab!;
      expect(tab.text, 'user');
      expect(tab.dirty, isTrue);
      expect(tab.content?.text, 'disk');
    });

    test('an edit landing during a reload triggers a follow-up read', () async {
      final completer = Completer<http.Response>();
      var call = 0;
      final client = ApiClient.withClient(
        MockClient((req) {
          call++;
          if (call == 2) return completer.future;
          return Future.value(_json(200, _fileJson('a.txt', 'v$call')));
        }),
      );
      final state = AppState.test(
        api: ApiService(client: client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFileNewTab('a.txt');

      unawaited(state.openAgentEditedFile('a.txt'));
      await Future.delayed(const Duration(milliseconds: 10));
      expect(state.activeEditorTab?.loading, isTrue);

      unawaited(state.openAgentEditedFile('a.txt'));
      completer.complete(_json(200, _fileJson('a.txt', 'v2')));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(call, 3);
      expect(state.activeEditorTab?.text, 'v3');
      expect(state.activeEditorTab?.loading, isFalse);
    });
  });
}
