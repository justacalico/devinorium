import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
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

  _Harness({Map<String, dynamic>? changes, Map<String, dynamic>? repo})
    : changesResponse = changes ?? _changes(),
      repoResponse = repo ?? _repoInfo();

  http.Request lastTo(String path, [String method = 'GET']) =>
      requests.lastWhere(
        (r) => r.url.path == path && r.method == method,
      );
}

AppState _state(ApiService api, {Thread? thread}) => AppState.test(
  api: api,
  projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
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

    test('a 404 marks the scope as not a repo without an error', () async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => _json(404, {'error': 'not a repo'})),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();
      expect(state.gitPanelChanges, isNull);
      expect(state.gitPanelRepoInfo, isNull);
      expect(state.gitPanelError, isEmpty);
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

    testWidgets('shows the not-a-repo placeholder', (tester) async {
      final state = _state(
        ApiService(
          client: ApiClient.withClient(
            MockClient((_) async => _json(404, {'error': 'not a repo'})),
          ),
        ),
      );
      addTearDown(state.dispose);
      await state.openGitPanel();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Not a git repository'), findsOneWidget);
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
  });
}
