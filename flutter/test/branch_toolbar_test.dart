import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/branch_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(false);

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

  @override
  Future<String?> get token => Future.value(null);
}

class _FakeApiService extends ApiService {
  _FakeApiService() : super(client: _ThrowingClient());

  final calls = <String>[];
  String currentBranch = 'main';
  int ahead = 0;
  int behind = 0;
  bool isRepo = true;
  bool failCreateBranch = false;
  bool failCreateWorktree = false;
  List<GitBranch> branches = [
    GitBranch(
      name: 'main',
      refname: 'refs/heads/main',
      isCurrent: true,
      isDefault: true,
      isRemote: false,
    ),
    GitBranch(
      name: 'feature',
      refname: 'refs/heads/feature',
      isCurrent: false,
      isDefault: false,
      isRemote: false,
    ),
    GitBranch(
      name: 'origin/feature',
      refname: 'refs/remotes/origin/feature',
      isCurrent: false,
      isDefault: false,
      isRemote: true,
    ),
  ];
  List<GitWorktree> worktrees = [];

  String? threadBranch;
  String? threadWorktreePath;

  @override
  Future<GitRepoInfo> gitRepoStatus(
    int projectId, {
    bool force = false,
    String? threadId,
  }) async {
    calls.add('gitRepoStatus:$projectId');
    return GitRepoInfo(
      isRepo: isRepo,
      branch: isRepo ? currentBranch : '',
      worktreePath: '/x',
      toplevel: '/x',
      commonDir: '/x/.git',
      ahead: isRepo ? ahead : 0,
      behind: isRepo ? behind : 0,
    );
  }

  @override
  Future<List<GitBranch>> gitBranches(
    int projectId, {
    String? query,
    int limit = 100,
    bool force = false,
  }) async {
    calls.add('gitBranches:$projectId');
    return branches;
  }

  @override
  Future<List<GitWorktree>> gitWorktrees(
    int projectId, {
    bool force = false,
  }) async {
    calls.add('gitWorktrees:$projectId');
    return worktrees;
  }

  @override
  Future<void> gitCheckout(
    int projectId,
    String refName, {
    bool track = false,
  }) async {
    calls.add('gitCheckout:$refName:$track');
    if (track) {
      currentBranch = refName.replaceAll('origin/', '');
    } else {
      currentBranch = refName;
    }
    branches = [
      ...branches.map(
        (b) => GitBranch(
          name: b.name,
          refname: b.refname,
          isCurrent: b.name == currentBranch,
          isDefault: b.isDefault,
          isRemote: b.isRemote,
        ),
      ),
    ];
  }

  @override
  Future<String> gitCreateBranch(
    int projectId,
    String name, {
    String? base,
    bool switchBranch = false,
  }) async {
    calls.add('gitCreateBranch:$name:$base:$switchBranch');
    if (failCreateBranch) throw Exception('create branch failed');
    if (switchBranch) currentBranch = name;
    return name;
  }

  @override
  Future<GitWorktree> gitCreateWorktree(
    int projectId,
    String name,
    String base, {
    bool newBranch = false,
  }) async {
    calls.add('gitCreateWorktree:$name:$base:$newBranch');
    if (failCreateWorktree) throw Exception('create worktree failed');
    final worktree = GitWorktree(
      path: '/x/$name',
      head: newBranch ? name : base,
      branch: newBranch ? name : base,
      isMain: false,
    );
    worktrees = [...worktrees, worktree];
    return worktree;
  }

  @override
  Future<void> gitPull(int projectId, {String? threadId}) async {
    calls.add('gitPull:$projectId');
  }

  @override
  Future<void> gitPush(int projectId, {String? threadId}) async {
    calls.add('gitPush:$projectId');
  }

  @override
  Future<MergeRequestLink?> findMergeRequestForBranch(
    int projectId,
    String branch,
  ) async {
    calls.add('findMergeRequestForBranch:$projectId:$branch');
    return null;
  }

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) async {
    calls.add('updateThreadSettings:$id:$envMode');
  }

  @override
  Future<void> updateThreadGit(
    String id, {
    String? branch,
    String? worktreePath,
  }) async {
    calls.add('updateThreadGit:$id:$branch:$worktreePath');
    threadBranch = branch;
    threadWorktreePath = worktreePath;
  }

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) async {
    calls.add('getThread:$id');
    return ThreadDetail(
      thread: Thread(
        id: id,
        title: 'Test',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        branch: threadBranch,
        worktreePath: threadWorktreePath,
        envMode: threadWorktreePath != null ? 'worktree' : 'local',
        createdAt: '',
        updatedAt: '',
      ),
      messages: const [],
    );
  }

  @override
  Future<Map<String, dynamic>> getThreadProject(String id) async {
    calls.add('getThreadProject:$id');
    return {'project_id': 1};
  }

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) async {
    calls.add('listThreads');
    return [];
  }

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) async {
    calls.add('listThreadGroups');
    return [];
  }

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) async {
    calls.add('listProjects');
    return [
      Project(
        id: 1,
        name: 'p',
        path: '/x',
        isRepo: true,
        gitBranch: currentBranch,
        createdAt: '',
        updatedAt: '',
      ),
    ];
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const Scaffold(body: BranchToolbar()),
  ),
);

AppState _testState(_FakeApiService api) => AppState.test(
  api: api,
  projects: [
    Project(
      id: 1,
      name: 'p',
      path: '/x',
      isRepo: true,
      gitBranch: 'main',
      createdAt: '',
      updatedAt: '',
    ),
  ],
  activeProjectId: 1,
  activeThreadId: 't1',
  activeThreadDetail: ThreadDetail(
    thread: Thread(
      id: 't1',
      title: 'Test',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      branch: 'stale',
      createdAt: '',
      updatedAt: '',
    ),
    messages: const [],
  ),
);

void main() {
  group('BranchToolbar', () {
    testWidgets('hides when no active thread', (tester) async {
      final state = AppState.test(
        api: _FakeApiService(),
        projects: [
          Project(
            id: 1,
            name: 'p',
            path: '/x',
            isRepo: true,
            gitBranch: 'main',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        activeProjectId: 1,
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuButton<String?>), findsNothing);
    });

    testWidgets('shows current repo branch, not stale thread branch', (
      tester,
    ) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('main'), findsWidgets);
      expect(find.text('stale'), findsNothing);
    });

    testWidgets('shows selected worktree branch when on a worktree', (
      tester,
    ) async {
      final api = _FakeApiService();
      api.worktrees = [
        GitWorktree(
          path: '/x/wt',
          head: 'abc',
          branch: 'worktree-branch',
          isMain: false,
        ),
      ];
      final state = AppState.test(
        api: api,
        projects: [
          Project(
            id: 1,
            name: 'p',
            path: '/x',
            isRepo: true,
            gitBranch: 'main',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            branch: 'main',
            worktreePath: '/x/wt',
            envMode: 'worktree',
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('worktree-branch'), findsWidgets);
    });

    testWidgets('switching branch checks out and updates thread', (
      tester,
    ) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('feature'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(api.currentBranch, 'feature');
      expect(api.calls, contains('gitCheckout:feature:false'));
      expect(api.calls, contains('updateThreadGit:t1:feature:null'));
    });

    testWidgets('checking out a remote branch tracks it', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('origin/feature'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(api.currentBranch, 'feature');
      expect(api.calls, contains('gitCheckout:origin/feature:true'));
      expect(api.calls, contains('updateThreadGit:t1:feature:null'));
    });

    testWidgets('selecting a worktree updates thread context', (tester) async {
      final api = _FakeApiService();
      api.worktrees = [
        GitWorktree(
          path: '/x/wt',
          head: 'abc',
          branch: 'wt-branch',
          isMain: false,
        ),
      ];
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_worktree')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('wt-branch'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(api.calls, contains('updateThreadGit:t1:wt-branch:/x/wt'));
    });

    testWidgets('create branch form opens and submits', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Branch name'),
        'new-branch',
      );
      await tester.pump();

      await tester.tap(find.text('Create and switch').last);
      await tester.pumpAndSettle();

      expect(api.calls, contains('gitCreateBranch:new-branch:null:true'));
      expect(api.calls, contains('updateThreadGit:t1:new-branch:null'));
    });

    testWidgets('pull and push buttons call their endpoints', (tester) async {
      final api = _FakeApiService();
      api.ahead = 2;
      api.behind = 1;
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('↓1').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('gitPull:1'));

      await tester.tap(find.text('↑2').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('gitPush:1'));
    });

    testWidgets('create worktree form opens and submits', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_worktree')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create worktree'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Worktree name'),
        'wt',
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create worktree'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('gitCreateWorktree:wt:main:false'));
      expect(api.calls, contains('updateThreadGit:t1:main:/x/wt'));
    });

    testWidgets('create branch with an explicit base', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String?>).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('feature'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Branch name'),
        'child',
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Create branch'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('gitCreateBranch:child:feature:false'));
    });

    testWidgets('create worktree with new branch switch', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_worktree')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create worktree'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Worktree name'),
        'wt',
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create worktree'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('gitCreateWorktree:wt:main:true'));
      expect(api.calls, contains('updateThreadGit:t1:wt:/x/wt'));
    });

    testWidgets(
      'create worktree keeps form open and surfaces an error on failure',
      (tester) async {
        final api = _FakeApiService();
        api.failCreateWorktree = true;
        final state = _testState(api);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('branch_toolbar_worktree')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create worktree'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Worktree name'),
          'bad',
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Create worktree'));
        await tester.pumpAndSettle();

        expect(api.calls, contains('gitCreateWorktree:bad:main:false'));
        expect(state.globalError, isNotEmpty);
        expect(find.widgetWithText(TextField, 'Worktree name'), findsOneWidget);
      },
    );

    testWidgets('hides when the project is not a git repo', (tester) async {
      final api = _FakeApiService();
      api.isRepo = false;
      final state = AppState.test(
        api: api,
        projects: [
          Project(
            id: 1,
            name: 'p',
            path: '/x',
            isRepo: false,
            gitBranch: '',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            branch: '',
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuButton<String?>), findsNothing);
    });

    testWidgets('branch checkout is disabled on a non-main worktree', (
      tester,
    ) async {
      final api = _FakeApiService();
      api.worktrees = [
        GitWorktree(
          path: '/x/wt',
          head: 'abc',
          branch: 'wt-branch',
          isMain: false,
        ),
      ];
      final state = AppState.test(
        api: api,
        projects: [
          Project(
            id: 1,
            name: 'p',
            path: '/x',
            isRepo: true,
            gitBranch: 'main',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 'Test',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            branch: 'main',
            worktreePath: '/x/wt',
            envMode: 'worktree',
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      // The branch selector is disabled on a non-main worktree.
      final branchButton = tester.widget<PopupMenuButton<String?>>(
        find.byKey(const Key('branch_toolbar_branch')),
      );
      expect(branchButton.enabled, isFalse);
      expect(api.calls.where((c) => c.startsWith('gitCheckout')), isEmpty);
    });

    testWidgets('empty branch name does not submit', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create and switch'));
      await tester.pumpAndSettle();

      expect(api.calls.where((c) => c.startsWith('gitCreateBranch')), isEmpty);
    });

    testWidgets('empty worktree name does not submit', (tester) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_worktree')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create worktree').first);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create worktree'));
      await tester.pumpAndSettle();

      expect(
        api.calls.where((c) => c.startsWith('gitCreateWorktree')),
        isEmpty,
      );
    });

    testWidgets('keeps the form open and surfaces an error on failure', (
      tester,
    ) async {
      final api = _FakeApiService();
      api.failCreateBranch = true;
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_branch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Branch name'),
        'bad',
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create and switch'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('gitCreateBranch:bad:null:true'));
      expect(state.globalError, isNotEmpty);
      // The form should still be visible so the user can correct and retry.
      expect(find.widgetWithText(TextField, 'Branch name'), findsOneWidget);
    });

    testWidgets('env mode menu switches between local and worktree', (
      tester,
    ) async {
      final api = _FakeApiService();
      final state = _testState(api);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('branch_toolbar_env_mode')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Worktree'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(api.calls, contains('updateThreadSettings:t1:worktree'));
    });
  });
}
