import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/services/editor_launcher.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLauncher implements EditorLauncher {
  _FakeLauncher({this.supported = true, this.editors = const []});

  final bool supported;
  final List<EditorApp> editors;
  final List<({String path, String editorId})> opened = [];

  @override
  bool get isSupported => supported;

  @override
  Future<List<EditorApp>> detectEditors() async => editors;

  @override
  Future<bool> open(String path, String editorId) async {
    opened.add((path: path, editorId: editorId));
    return true;
  }
}

const _editor = EditorApp(id: 'vscode', label: 'VS Code', commands: ['code']);

User _user() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

Project _project({int id = 1, String path = '/repo', String? nodeId}) =>
    Project(
      id: id,
      name: 'repo',
      path: path,
      nodeId: nodeId,
      createdAt: '',
      updatedAt: '',
    );

Thread _thread({String? worktreePath, int projectId = 1}) => Thread(
  id: 't1',
  title: 'Test thread',
  projectId: projectId,
  model: 'm1',
  permissionMode: 'normal',
  worktreePath: worktreePath,
  createdAt: '',
  updatedAt: '',
);

/// A MultiServerState whose active profile is the bundled local server (or a
/// plain remote profile when [isLocal] is false).
MultiServerState _servers({required bool isLocal}) {
  final multi = MultiServerState();
  multi.addTestConnection(
    ServerProfile(
      id: isLocal ? 'local' : 'remote',
      label: 'test',
      baseUrl: 'http://test',
      token: 'token',
      username: 'test',
      createdAt: DateTime(2024),
      isPrimary: true,
      isLocal: isLocal,
    ),
    // The button never calls the API; the profile flag is what matters.
    // ignore: prefer_const_constructors
    ApiService(),
  );
  return multi;
}

Widget _page(AppState state, EditorLauncher launcher) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: ThreadPage(openInLauncher: launcher),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the open-in button for bundled server threads', (
    tester,
  ) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project()],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(thread: _thread()),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_in_primary')), findsOneWidget);
    expect(find.byKey(const Key('open_in_menu')), findsOneWidget);

    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (path: '/repo', editorId: 'vscode'));
  });

  testWidgets('is hidden for remote server profiles', (tester) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: false),
      user: _user(),
      projects: [_project()],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(thread: _thread()),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('is hidden for projects hosted on a satellite node', (
    tester,
  ) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project(nodeId: 'node-1')],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(thread: _thread()),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('prefers the thread worktree over the project path', (
    tester,
  ) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project()],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread(worktreePath: '/repo/.worktrees/feat'),
      ),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (
      path: '/repo/.worktrees/feat',
      editorId: 'vscode',
    ));
  });

  testWidgets('is hidden when the project has not loaded yet', (tester) async {
    // The project list is paginated — without the project we cannot tell
    // whether it lives on a satellite node, so the button stays hidden even
    // when the thread advertises a worktree path.
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: const [],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread(worktreePath: '/repo/.worktrees/feat'),
      ),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('is hidden when the thread has no resolvable path', (
    tester,
  ) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project(path: '')],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(thread: _thread()),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('is hidden when no thread is open', (tester) async {
    final launcher = _FakeLauncher(editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project()],
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('is hidden when the platform cannot launch editors', (
    tester,
  ) async {
    final launcher = _FakeLauncher(supported: false, editors: [_editor]);
    final state = AppState.test(
      multiServerState: _servers(isLocal: true),
      user: _user(),
      projects: [_project()],
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(thread: _thread()),
    );

    await tester.pumpWidget(_page(state, launcher));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });
}
