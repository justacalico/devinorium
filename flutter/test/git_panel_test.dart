import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/diff_view.dart';
import 'package:devinorium_frontend/views/git_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _repoInfo({String branch = 'main'}) => {
  'is_repo': true,
  'branch': branch,
  'worktree_path': '/x',
  'toplevel': '/x',
  'common_dir': '/x/.git',
  'ahead': 0,
  'behind': 0,
};

Map<String, dynamic> _changes({
  String branch = 'main',
  List<Map<String, dynamic>> staged = const [],
  List<Map<String, dynamic>> unstaged = const [],
}) => {
  'branch': branch,
  'ahead': 0,
  'behind': 0,
  'staged': staged,
  'unstaged': unstaged,
};

/// Mock client that records requests and serves git panel responses.
class _Harness {
  final List<http.Request> requests = [];

  late final ApiService api = ApiService(
    client: ApiClient.withClient(
      MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        if (path == '/api/projects/1/git/changes') {
          return _json(200, changesResponse);
        }
        if (path == '/api/projects/1/git') {
          return _json(200, repoResponse);
        }
        if (path == '/api/projects/1/git/diff') {
          if (legacyBackend) return http.Response('not found', 404);
          return _json(200, diffResponse);
        }
        if (path == '/api/projects/1/git/log') {
          if (legacyBackend) return http.Response('not found', 404);
          return _json(200, logResponse(req.url));
        }
        if (path == '/api/projects/1/git/discard') {
          if (legacyBackend) return http.Response('not found', 404);
          return _json(204, {});
        }
        if (path == '/api/projects/1/git/stage' ||
            path == '/api/projects/1/git/unstage' ||
            path == '/api/projects/1/git/pull' ||
            path == '/api/projects/1/git/push') {
          return _json(204, {});
        }
        if (path == '/api/projects/1/git/commit') {
          return _json(200, {'sha': 'abc123', 'subject': 'wip'});
        }
        return _json(404, {'error': 'unexpected $path'});
      }),
    ),
  );

  Map<String, dynamic> changesResponse;
  Map<String, dynamic> repoResponse;

  /// The whole `{"diff": ...}` body for `/git/diff`; `{'diff': null}` means
  /// "nothing renderable".
  Map<String, dynamic> diffResponse;

  /// `/git/log` response factory — receives the request URI so tests can
  /// answer differently per page.
  Map<String, dynamic> Function(Uri url) logResponse;

  /// Simulates a backend that predates the diff/discard/log routes: they
  /// answer with the SPA fallback's plain-text 404.
  bool legacyBackend = false;

  _Harness({
    Map<String, dynamic>? changes,
    Map<String, dynamic>? repo,
    Map<String, dynamic>? diff,
    Map<String, dynamic> Function(Uri url)? log,
  }) : changesResponse = changes ?? _changes(),
       repoResponse = repo ?? _repoInfo(),
       diffResponse = diff ?? const {'diff': null},
       logResponse =
           log ??
           ((_) => {'commits': <Map<String, dynamic>>[], 'has_more': false});

  http.Request lastTo(String path, [String method = 'GET']) =>
      requests.lastWhere((r) => r.url.path == path && r.method == method);
}

Map<String, dynamic> _commit(String sha, String subject, {String body = ''}) =>
    {
      'sha': sha.padRight(40, '0'),
      'subject': subject,
      'body': body,
      'author': 'Test',
      'email': 'test@example.com',
      'timestamp': 1700000000,
      'refs': '',
    };

AppState _state(ApiService api, {Thread? thread}) => AppState.test(
  api: api,
  projects: [
    Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
  ],
  activeProjectId: 1,
  activeThreadId: thread?.id,
  activeThreadDetail: thread == null
      ? null
      : ThreadDetail(thread: thread, messages: const []),
);

Widget _buildWithState(AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: GitPanel())),
    );

void main() {
  group('GitPanelStore', () {
    test('openGitPanel loads changes and closes the files panel', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);

      await state.openGitPanel();
      expect(state.gitPanelOpen, isTrue);
      expect(state.filesPanelOpen, isFalse);
      expect(state.gitPanelChanges?.unstaged, hasLength(1));
      expect(state.gitPanelChanges?.unstaged.first.path, 'a.txt');
      expect(state.gitPanelRepoInfo?.branch, 'main');
      expect(state.gitPanelError, isEmpty);
      expect(state.gitPanelScopeKey, 'project:1');
    });

    test('a not-a-repo 404 marks the scope without an error', () async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient(
              (_) async => _json(404, {'error': 'not a git repository'}),
            ),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelChanges, isNull);
      expect(state.gitPanelRepoInfo, isNull);
      expect(state.gitPanelError, isEmpty);
      expect(state.gitPanelUnsupported, isFalse);
    });

    test('a routing 404 means the backend lacks the git endpoints', () async {
      // An older backend has no /git routes; the SPA fallback answers with a
      // plain-text 404 that is not the git API's error shape.
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => http.Response('not found', 404)),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelChanges, isNull);
      expect(state.gitPanelRepoInfo, isNull);
      expect(state.gitPanelError, isEmpty);
      expect(state.gitPanelUnsupported, isTrue);
    });

    test('a json 404 for another reason surfaces as an error', () async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => _json(404, {'error': 'project not found'})),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelChanges, isNull);
      expect(state.gitPanelError, 'project not found');
      expect(state.gitPanelUnsupported, isFalse);
    });

    test('gitStagePaths posts paths then reloads changes', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      h.changesResponse = _changes(staged: [
        {'path': 'a.txt', 'status': 'modified'},
      ]);
      final ok = await state.gitStagePaths(['a.txt']);
      expect(ok, isTrue);

      final req = h.lastTo('/api/projects/1/git/stage', 'POST');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['paths'], ['a.txt']);
      expect(body['all'], isFalse);
      expect(state.gitPanelChanges?.staged, hasLength(1));
      expect(state.gitPanelChanges?.unstaged, isEmpty);
    });

    test('gitUnstagePaths posts paths', () async {
      final h = _Harness(
        changes: _changes(staged: [
          {'path': 'a.txt', 'status': 'added'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      h.changesResponse = _changes();
      final ok = await state.gitUnstagePaths(['a.txt']);
      expect(ok, isTrue);
      final req = h.lastTo('/api/projects/1/git/unstage', 'POST');
      expect((jsonDecode(req.body) as Map)['paths'], ['a.txt']);
      expect(state.gitPanelChanges?.staged, isEmpty);
    });

    test('stageAll and unstageAll send the all flag', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.gitStageAll();
      var body =
          jsonDecode(h.lastTo('/api/projects/1/git/stage', 'POST').body)
              as Map<String, dynamic>;
      expect(body['all'], isTrue);
      expect(body['paths'], isEmpty);

      await state.gitUnstageAll();
      body =
          jsonDecode(h.lastTo('/api/projects/1/git/unstage', 'POST').body)
              as Map<String, dynamic>;
      expect(body['all'], isTrue);
    });

    test('commit sends all=false when files are staged', () async {
      final h = _Harness(
        changes: _changes(staged: [
          {'path': 'a.txt', 'status': 'added'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      h.changesResponse = _changes();
      final ok = await state.gitCommitChanges('wip');
      expect(ok, isTrue);
      final body =
          jsonDecode(h.lastTo('/api/projects/1/git/commit', 'POST').body)
              as Map<String, dynamic>;
      expect(body['message'], 'wip');
      expect(body['all'], isFalse);
    });

    test('commit sends all=true when nothing is staged', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      h.changesResponse = _changes();
      final ok = await state.gitCommitChanges('wip');
      expect(ok, isTrue);
      final body =
          jsonDecode(h.lastTo('/api/projects/1/git/commit', 'POST').body)
              as Map<String, dynamic>;
      expect(body['all'], isTrue);
    });

    test('commit rejects an empty message without a request', () async {
      final h = _Harness();
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();
      final before = h.requests.length;
      expect(await state.gitCommitChanges('   '), isFalse);
      expect(h.requests.length, before);
    });

    test('errors are surfaced in gitPanelError', () async {
      final state = AppState.test(
        api: ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => _json(500, {'error': 'boom'})),
          ),
        ),
        activeProjectId: 1,
      );
      addTearDown(state.dispose);
      expect(await state.gitStageAll(), isFalse);
      expect(state.gitPanelError, contains('boom'));
    });

    test('worktree scope sends thread_id on every git call', () async {
      final h = _Harness(
        repo: _repoInfo(branch: 'wt-branch'),
        changes: _changes(
          branch: 'wt-branch',
          unstaged: [
            {'path': 'a.txt', 'status': 'modified'},
          ],
        ),
      );
      final thread = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        model: 'm',
        permissionMode: 'normal',
        envMode: 'worktree',
        worktreePath: '/repo/wt',
        createdAt: '',
        updatedAt: '',
      );
      final state = _state(h.api, thread: thread);
      addTearDown(state.dispose);

      await state.openGitPanel();
      expect(state.gitPanelScopeKey, 'worktree:/repo/wt');
      expect(state.gitApiThreadId, 't1');
      expect(state.gitPanelChanges?.branch, 'wt-branch');

      var req = h.lastTo('/api/projects/1/git/changes');
      expect(req.url.queryParameters['thread_id'], 't1');
      req = h.lastTo('/api/projects/1/git');
      expect(req.url.queryParameters['thread_id'], 't1');

      await state.gitStageAll();
      var body =
          jsonDecode(h.lastTo('/api/projects/1/git/stage', 'POST').body)
              as Map<String, dynamic>;
      expect(body['thread_id'], 't1');

      await state.gitPanelPull();
      body =
          jsonDecode(h.lastTo('/api/projects/1/git/pull', 'POST').body)
              as Map<String, dynamic>;
      expect(body['thread_id'], 't1');

      await state.gitPanelPush();
      body =
          jsonDecode(h.lastTo('/api/projects/1/git/push', 'POST').body)
              as Map<String, dynamic>;
      expect(body['thread_id'], 't1');

      await state.gitCommitChanges('wip');
      body =
          jsonDecode(h.lastTo('/api/projects/1/git/commit', 'POST').body)
              as Map<String, dynamic>;
      expect(body['thread_id'], 't1');
    });

    test('project scope sends no thread_id', () async {
      final h = _Harness();
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelScopeKey, 'project:1');
      expect(state.gitApiThreadId, isNull);
      final req = h.lastTo('/api/projects/1/git/changes');
      expect(req.url.queryParameters.containsKey('thread_id'), isFalse);
    });

    test('actions stay pinned to the loaded project', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = AppState.test(
        api: h.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'q', path: '/y', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelScopeKey, 'project:1');

      // Switch project before the next refresh lands; the action must still
      // hit the project the displayed data belongs to.
      await state.selectProject(2);
      await state.gitStageAll();
      final req = h.lastTo('/api/projects/1/git/stage', 'POST');
      expect((jsonDecode(req.body) as Map)['all'], isTrue);
    });

    test('opening the files panel closes the git panel', () async {
      final h = _Harness();
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelOpen, isTrue);
      // openFilesPanel hits /api/files; the harness 404s it, which only
      // records an error — the flag flips regardless.
      await state.openFilesPanel();
      expect(state.gitPanelOpen, isFalse);
      expect(state.filesPanelOpen, isTrue);
    });

    test('toggleGitDiff fetches an unstaged diff and caches it', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
        diff: {
          'diff': {
            'path': '/x/a.txt',
            'old_text': 'old\n',
            'new_text': 'new\n',
          },
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      final entry = state.gitPanelChanges!.unstaged.first;
      await state.toggleGitDiff(entry, staged: false);

      final req = h.lastTo('/api/projects/1/git/diff');
      expect(req.url.queryParameters['path'], 'a.txt');
      expect(req.url.queryParameters.containsKey('staged'), isFalse);
      expect(req.url.queryParameters.containsKey('orig_path'), isFalse);
      expect(state.gitDiffExpanded('u:a.txt'), isTrue);
      expect(state.gitDiffFor('u:a.txt')?.newText, 'new\n');

      // Collapsing removes it from the expanded set without another fetch.
      final before = h.requests.length;
      await state.toggleGitDiff(entry, staged: false);
      expect(state.gitDiffExpanded('u:a.txt'), isFalse);
      expect(h.requests.length, before);
    });

    test('a staged diff sends staged and orig_path', () async {
      final h = _Harness(
        changes: _changes(staged: [
          {'path': 'b.txt', 'status': 'renamed', 'orig_path': 'a.txt'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitDiff(
        state.gitPanelChanges!.staged.first,
        staged: true,
      );

      final req = h.lastTo('/api/projects/1/git/diff');
      expect(req.url.queryParameters['path'], 'b.txt');
      expect(req.url.queryParameters['staged'], 'true');
      expect(req.url.queryParameters['orig_path'], 'a.txt');
      expect(state.gitDiffExpanded('s:b.txt'), isTrue);
    });

    test('a failed diff fetch leaves a null preview, not an error', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      // The default harness answers {'diff': null} — a binary or oversized
      // file, or a backend that found nothing to compare.
      await state.toggleGitDiff(
        state.gitPanelChanges!.unstaged.first,
        staged: false,
      );
      expect(state.gitDiffExpanded('u:a.txt'), isTrue);
      expect(state.gitDiffLoading('u:a.txt'), isFalse);
      expect(state.gitDiffFor('u:a.txt'), isNull);
      expect(state.gitPanelError, isEmpty);
    });

    test('a reload drops previews whose file left the change list', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
        diff: {
          'diff': {'path': '/x/a.txt', 'old_text': 'o\n', 'new_text': 'n\n'},
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitDiff(
        state.gitPanelChanges!.unstaged.first,
        staged: false,
      );
      expect(state.gitDiffFor('u:a.txt'), isNotNull);

      // The file got committed or reverted elsewhere.
      h.changesResponse = _changes();
      await state.reloadGitChanges();
      expect(state.gitDiffExpanded('u:a.txt'), isFalse);
      expect(state.gitDiffFor('u:a.txt'), isNull);
    });

    test('a reload re-fetches still-expanded diffs', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
        diff: {
          'diff': {'path': '/x/a.txt', 'old_text': 'o\n', 'new_text': 'n\n'},
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitDiff(
        state.gitPanelChanges!.unstaged.first,
        staged: false,
      );
      final before = h.requests
          .where((r) => r.url.path.endsWith('/git/diff'))
          .length;

      h.diffResponse = {
        'diff': {'path': '/x/a.txt', 'old_text': 'o\n', 'new_text': 'n2\n'},
      };
      await state.reloadGitChanges();
      // The refresh refetches in the background; give it a turn.
      for (var i = 0; i < 50 && state.gitDiffLoading('u:a.txt'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(state.gitDiffFor('u:a.txt')?.newText, 'n2\n');
      final after = h.requests
          .where((r) => r.url.path.endsWith('/git/diff'))
          .length;
      expect(after, greaterThan(before));
    });

    test('gitDiscardPaths posts the paths then reloads', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      h.changesResponse = _changes();
      expect(await state.gitDiscardPaths(['a.txt'], staged: false), isTrue);

      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['paths'], ['a.txt']);
      expect(body['staged'], isFalse);
      expect(state.gitPanelChanges?.unstaged, isEmpty);
    });

    test('discard and diff carry thread_id in a worktree scope', () async {
      final h = _Harness(
        changes: _changes(
          branch: 'wt-branch',
          unstaged: [
            {'path': 'a.txt', 'status': 'modified'},
          ],
        ),
      );
      final thread = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        model: 'm',
        permissionMode: 'normal',
        envMode: 'worktree',
        worktreePath: '/repo/wt',
        createdAt: '',
        updatedAt: '',
      );
      final state = _state(h.api, thread: thread);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitDiff(
        state.gitPanelChanges!.unstaged.first,
        staged: false,
      );
      expect(
        h.lastTo('/api/projects/1/git/diff').url.queryParameters['thread_id'],
        't1',
      );

      await state.gitDiscardPaths(['a.txt'], staged: false);
      final body =
          jsonDecode(h.lastTo('/api/projects/1/git/discard', 'POST').body)
              as Map<String, dynamic>;
      expect(body['thread_id'], 't1');
    });

    test(
      'history loads the first page on open and appends on loadMore',
      () async {
        final h = _Harness(
          log: (url) {
            final offset =
                int.tryParse(url.queryParameters['offset'] ?? '0') ?? 0;
            if (offset == 0) {
              return {
                'commits': [_commit('aaaa', 'newer commit')],
                'has_more': true,
              };
            }
            return {
              'commits': [_commit('bbbb', 'older commit')],
              'has_more': false,
            };
          },
        );
        final state = _state(h.api);
        addTearDown(state.dispose);
        await state.openGitPanel();

        await state.toggleGitHistory();
        expect(state.gitHistoryOpen, isTrue);
        expect(state.gitHistory, hasLength(1));
        expect(state.gitHistory.first.subject, 'newer commit');
        expect(state.gitHistoryHasMore, isTrue);

        await state.loadMoreGitHistory();
        expect(state.gitHistory, hasLength(2));
        expect(state.gitHistory.last.subject, 'older commit');
        expect(state.gitHistoryHasMore, isFalse);

        final req = h.requests.lastWhere(
          (r) =>
              r.url.path == '/api/projects/1/git/log' &&
              r.url.queryParameters['offset'] == '1',
        );
        expect(req, isNotNull);

        // Closing the section keeps the loaded commits for next open.
        await state.toggleGitHistory();
        expect(state.gitHistoryOpen, isFalse);
        expect(state.gitHistory, hasLength(2));
      },
    );

    test('history sends thread_id in a worktree scope', () async {
      final h = _Harness(
        log: (_) => {
          'commits': [_commit('aaaa', 'wt commit')],
          'has_more': false,
        },
      );
      final thread = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        model: 'm',
        permissionMode: 'normal',
        envMode: 'worktree',
        worktreePath: '/repo/wt',
        createdAt: '',
        updatedAt: '',
      );
      final state = _state(h.api, thread: thread);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitHistory();
      expect(state.gitHistory, hasLength(1));
      expect(
        h.lastTo('/api/projects/1/git/log').url.queryParameters['thread_id'],
        't1',
      );
    });

    test('a missing log endpoint leaves an empty quiet history', () async {
      final h = _Harness()..legacyBackend = true;
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await state.toggleGitHistory();
      expect(state.gitHistory, isEmpty);
      expect(state.gitHistoryError, isEmpty);
      expect(state.gitHistoryHasMore, isFalse);

      // The legacy endpoint is marked loaded so the periodic refresh does
      // not keep polling a route that will never appear.
      await state.refreshGitPanel();
      expect(
        h.requests.where((r) => r.url.path.endsWith('/git/log')).length,
        1,
      );
    });

    test('legacy backend diff and discard fail quietly', () async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      )..legacyBackend = true;
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      // The preview expands, fails to load, and shows the placeholder —
      // no error surfaces for a route that does not exist.
      await state.toggleGitDiff(
        state.gitPanelChanges!.unstaged.first,
        staged: false,
      );
      expect(state.gitDiffExpanded('u:a.txt'), isTrue);
      expect(state.gitDiffFor('u:a.txt'), isNull);
      expect(state.gitPanelError, isEmpty);

      expect(await state.gitDiscardPaths(['a.txt'], staged: false), isFalse);
    });

    test(
      'loadMore drops commits already shown after an offset shift',
      () async {
        // A commit landing between page loads shifts the offset window, so
        // the boundary commit can be returned twice; it must not repeat.
        final h = _Harness(
          log: (url) {
            final offset =
                int.tryParse(url.queryParameters['offset'] ?? '0') ?? 0;
            if (offset == 0) {
              return {
                'commits': [_commit('aaaa', 'newest')],
                'has_more': true,
              };
            }
            return {
              'commits': [_commit('aaaa', 'newest'), _commit('bbbb', 'older')],
              'has_more': false,
            };
          },
        );
        final state = _state(h.api);
        addTearDown(state.dispose);
        await state.openGitPanel();
        await state.toggleGitHistory();
        expect(state.gitHistory, hasLength(1));

        await state.loadMoreGitHistory();
        expect(state.gitHistory.map((c) => c.sha), [
          'aaaa'.padRight(40, '0'),
          'bbbb'.padRight(40, '0'),
        ]);
      },
    );

    test('a history load finishing after a scope change is dropped', () async {
      final wt = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        model: 'm',
        permissionMode: 'normal',
        envMode: 'worktree',
        worktreePath: '/repo/wt',
        createdAt: '',
        updatedAt: '',
      );
      final gate = Completer<http.Response>();
      var logCalls = 0;
      final api = ApiService(
        client: ApiClient.withClient(
          MockClient((req) async {
            final path = req.url.path;
            if (path == '/api/projects/1/git/changes') {
              return _json(200, _changes());
            }
            if (path == '/api/projects/1/git') {
              return _json(200, _repoInfo());
            }
            if (path == '/api/projects/1/git/log') {
              logCalls++;
              // The first page stays in flight until the scope has moved.
              if (logCalls == 1) return gate.future;
              return _json(200, {
                'commits': [_commit('cccc', 'new scope commit')],
                'has_more': false,
              });
            }
            return _json(404, {'error': 'unexpected $path'});
          }),
        ),
      );
      final state = AppState.test(
        api: api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        threads: [wt],
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelScopeKey, 'project:1');

      unawaited(state.toggleGitHistory());
      // Move the active thread into its worktree, then refresh the panel
      // so it picks up the new scope before the first page returns.
      await state.openThread('t1');
      await state.reloadGitChanges();
      expect(state.gitPanelScopeKey, 'worktree:/repo/wt');

      gate.complete(
        _json(200, {
          'commits': [_commit('aaaa', 'stale commit')],
          'has_more': false,
        }),
      );
      // Let the in-flight load resolve and try to write its stale page.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(state.gitHistory.map((c) => c.subject), ['new scope commit']);
    });

    test('a mutation while history is closed reloads it on reopen', () async {
      final h = _Harness(
        log: (_) => {
          'commits': [_commit('aaaa', 'first page')],
          'has_more': false,
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();
      await state.toggleGitHistory();
      expect(state.gitHistory.map((c) => c.subject), ['first page']);

      await state.toggleGitHistory(); // close
      await state.gitStagePaths(['a.txt']); // a commit/stage moves HEAD
      expect(
        h.requests.where((r) => r.url.path == '/api/projects/1/git/log'),
        hasLength(1),
      );

      await state.toggleGitHistory(); // reopen fetches a fresh page
      expect(
        h.requests.where((r) => r.url.path == '/api/projects/1/git/log'),
        hasLength(2),
      );
    });
  });

  group('GitPanel widget', () {
    testWidgets('renders branch, sections, and file rows', (tester) async {
      final h = _Harness(
        repo: _repoInfo(),
        changes: _changes(
          branch: 'feat/x',
          staged: [
            {'path': 'lib/staged.dart', 'status': 'added'},
          ],
          unstaged: [
            {'path': 'lib/modified.dart', 'status': 'modified'},
            {'path': 'new.txt', 'status': 'untracked'},
          ],
        ),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('feat/x'), findsOneWidget);
      expect(find.text('STAGED CHANGES (1)'), findsOneWidget);
      expect(find.text('CHANGES (2)'), findsOneWidget);
      expect(
        find.text('staged.dart  lib', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('modified.dart  lib', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('new.txt', findRichText: true), findsOneWidget);
      // Status letters: A added, M modified, U untracked.
      expect(find.text('A'), findsOneWidget);
      expect(find.text('M'), findsOneWidget);
      expect(find.text('U'), findsOneWidget);
    });

    testWidgets('stage and unstage buttons call the api', (tester) async {
      final h = _Harness(
        changes: _changes(
          staged: [
            {'path': 's.txt', 'status': 'added'},
          ],
          unstaged: [
            {'path': 'u.txt', 'status': 'modified'},
          ],
        ),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      // The staged row's trailing button un stages; the unstaged row's stages.
      final unstageBtn = find.byTooltip('Unstage');
      final stageBtn = find.byTooltip('Stage');
      expect(unstageBtn, findsOneWidget);
      expect(stageBtn, findsOneWidget);

      await tester.tap(stageBtn);
      await tester.pumpAndSettle();
      expect(
        h.requests.any((r) => r.url.path.endsWith('/git/stage')),
        isTrue,
      );

      await tester.tap(unstageBtn);
      await tester.pumpAndSettle();
      expect(
        h.requests.any((r) => r.url.path.endsWith('/git/unstage')),
        isTrue,
      );
    });

    testWidgets('commit button stays disabled without a message', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Commit'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('commit asks to stage-all when nothing is staged', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'wip');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Commit').last);
      await tester.pumpAndSettle();

      final body =
          jsonDecode(h.lastTo('/api/projects/1/git/commit', 'POST').body)
              as Map<String, dynamic>;
      expect(body['message'], 'wip');
      expect(body['all'], isTrue);
    });

    testWidgets('pull and push buttons hit the endpoints', (tester) async {
      final h = _Harness();
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Pull'));
      await tester.pumpAndSettle();
      expect(
        h.requests.any((r) => r.url.path.endsWith('/git/pull')),
        isTrue,
      );

      await tester.tap(find.byTooltip('Push'));
      await tester.pumpAndSettle();
      expect(
        h.requests.any((r) => r.url.path.endsWith('/git/push')),
        isTrue,
      );
    });

    testWidgets('editor mode with no thread shows the thread placeholder', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      state.setAppMode(AppMode.editor);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Select or create a thread'), findsOneWidget);
      expect(find.text('a.txt', findRichText: true), findsNothing);
      expect(find.byTooltip('Refresh'), findsNothing);
    });

    testWidgets('agents mode with no thread still shows project changes', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('a.txt', findRichText: true), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('worktree thread shows its changes, not the repo placeholder', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(
          branch: 'wt-branch',
          unstaged: [
            {'path': 'a.txt', 'status': 'modified'},
          ],
        ),
      );
      final thread = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        model: 'm',
        permissionMode: 'normal',
        envMode: 'worktree',
        worktreePath: '/repo/wt',
        createdAt: '',
        updatedAt: '',
      );
      final state = _state(h.api, thread: thread);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Not a git repository'), findsNothing);
      expect(find.text('wt-branch'), findsOneWidget);
      expect(find.text('a.txt', findRichText: true), findsOneWidget);
      expect(
        h.requests.any(
          (r) =>
              r.url.path.endsWith('/git/changes') &&
              r.url.queryParameters['thread_id'] == 't1',
        ),
        isTrue,
      );
    });

    testWidgets('shows the not-a-repo placeholder', (tester) async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient(
              (_) async => _json(404, {'error': 'not a git repository'}),
            ),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Not a git repository'), findsOneWidget);
    });

    testWidgets('an old backend shows the unsupported message', (tester) async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => http.Response('not found', 404)),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Not a git repository'), findsNothing);
      expect(
        find.text(
          'This server is too old for the Git panel. '
          'Update the backend and restart the app.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('refresh button reloads', (tester) async {
      final h = _Harness();
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();
      final before = h.requests
          .where((r) => r.url.path.endsWith('/git/changes'))
          .length;

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      final after = h.requests
          .where((r) => r.url.path.endsWith('/git/changes'))
          .length;
      expect(after, greaterThan(before));
    });

    testWidgets('tapping a change row expands an inline diff', (tester) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
        diff: {
          'diff': {
            'path': '/x/a.txt',
            'old_text': 'old line\n',
            'new_text': 'new line\n',
          },
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsNothing);

      await tester.tap(find.text('a.txt', findRichText: true));
      await tester.pumpAndSettle();

      expect(find.byType(DiffView), findsOneWidget);
      expect(
        find.textContaining('- old line', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('+ new line', findRichText: true),
        findsOneWidget,
      );

      // Tapping again collapses it.
      await tester.tap(find.text('a.txt', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byType(DiffView), findsNothing);
    });

    testWidgets('a null diff shows the placeholder text', (tester) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.txt', findRichText: true));
      await tester.pumpAndSettle();

      expect(find.text('No diff preview available'), findsOneWidget);
    });

    testWidgets('discard asks for confirmation and posts the paths', (
      tester,
    ) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Discard all changes to a.txt? This cannot be undone.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();

      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      expect((jsonDecode(req.body) as Map)['paths'], ['a.txt']);
    });

    testWidgets('cancelling discard sends no request', (tester) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'a.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(
        h.requests.any((r) => r.url.path.endsWith('/git/discard')),
        isFalse,
      );
    });

    testWidgets('untracked discard confirmation offers Delete', (tester) async {
      final h = _Harness(
        changes: _changes(unstaged: [
          {'path': 'scratch.txt', 'status': 'untracked'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Permanently delete scratch.txt? This cannot be undone.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      expect((jsonDecode(req.body) as Map)['paths'], ['scratch.txt']);
    });

    testWidgets('a staged rename discard covers both paths', (tester) async {
      final h = _Harness(
        changes: _changes(staged: [
          {'path': 'b.txt', 'status': 'renamed', 'orig_path': 'a.txt'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();

      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['paths'], ['b.txt', 'a.txt']);
      // A staged row resets the index and worktree to HEAD.
      expect(body['staged'], isTrue);
    });

    testWidgets('discard all posts every unstaged path', (tester) async {
      final h = _Harness(
        changes: _changes(
          unstaged: [
            {'path': 'a.txt', 'status': 'modified'},
            {'path': 'b.txt', 'status': 'untracked'},
          ],
        ),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discard all'));
      await tester.pumpAndSettle();
      expect(find.text('Discard all 2 changed files? This cannot be undone.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Discard all'));
      await tester.pumpAndSettle();
      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['paths'], ['a.txt', 'b.txt']);
      expect(body['staged'], isFalse);
    });

    testWidgets('staged discard all sends the staged flag', (tester) async {
      final h = _Harness(
        changes: _changes(staged: [
          {'path': 's.txt', 'status': 'modified'},
        ]),
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discard all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard all'));
      await tester.pumpAndSettle();

      final req = h.lastTo('/api/projects/1/git/discard', 'POST');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['paths'], ['s.txt']);
      expect(body['staged'], isTrue);
    });

    testWidgets('history section lists commits and loads more', (tester) async {
      final h = _Harness(
        log: (url) {
          final offset =
              int.tryParse(url.queryParameters['offset'] ?? '0') ?? 0;
          if (offset == 0) {
            return {
              'commits': [_commit('aaaa', 'newer commit', body: 'details\n')],
              'has_more': true,
            };
          }
          return {
            'commits': [_commit('bbbb', 'older commit')],
            'has_more': false,
          };
        },
      );
      final state = _state(h.api);
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('HISTORY'));
      await tester.pumpAndSettle();

      expect(find.text('aaaa000'), findsOneWidget);
      expect(find.text('newer commit'), findsOneWidget);
      expect(find.textContaining('Test ·'), findsOneWidget);

      // Expanding a commit shows its body and full sha.
      await tester.tap(find.text('newer commit'));
      await tester.pumpAndSettle();
      expect(find.text('details'), findsOneWidget);
      await tester.tap(find.text('newer commit'));
      await tester.pumpAndSettle();
      expect(find.text('details'), findsNothing);

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.text('older commit'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });
  });
}
