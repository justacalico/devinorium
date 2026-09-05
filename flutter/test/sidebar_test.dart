import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

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
  }) => throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  final deletedThreadIds = <String>[];
  final deletedProjectIds = <int>[];
  final pinnedProjectIds = <int>[];
  final unpinnedProjectIds = <int>[];
  final pinnedThreadIds = <String>[];
  final unpinnedThreadIds = <String>[];
  final pinProjectReturns = <int, Project>{};
  final pinThreadReturns = <String, Thread>{};
  List<Thread> listThreadsResult = const [];
  bool healthOk = true;

  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<void> deleteThread(String id) {
    deletedThreadIds.add(id);
    return Future.value();
  }

  @override
  Future<void> deleteProject(int id) {
    deletedProjectIds.add(id);
    return Future.value();
  }

  @override
  Future<Project> pinProject(int id, bool pinned) {
    if (pinned) {
      pinnedProjectIds.add(id);
    } else {
      unpinnedProjectIds.add(id);
    }
    return Future.value(
      pinProjectReturns[id] ??
          Project(
            id: id,
            name: 'project $id',
            path: '/x',
            pinned: pinned,
            createdAt: '',
            updatedAt: '',
          ),
    );
  }

  @override
  Future<Thread> pinThread(String id, bool pinned) {
    if (pinned) {
      pinnedThreadIds.add(id);
    } else {
      unpinnedThreadIds.add(id);
    }
    return Future.value(
      pinThreadReturns[id] ??
          Thread(
            id: id,
            title: 'thread $id',
            projectId: 0,
            model: '',
            permissionMode: 'normal',
            pinned: pinned,
            createdAt: '',
            updatedAt: '',
          ),
    );
  }

  @override
  Future<bool> checkHealth() => Future.value(healthOk);

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value([...listThreadsResult]);

  @override
  Future<List<Thread>> listThreadsForProject(
    int id, {
    int? limit,
    int? offset,
  }) => Future.value([]);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value([]);

  @override
  Future<GitRepoInfo> gitRepoStatus(int projectId, {bool force = false}) =>
      Future.value(GitRepoInfo());

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle'});

  @override
  Future<List<String>> getThreadRuns() => Future.value([]);
}

Widget _buildWithState(AppState state, {TargetPlatform? platform}) =>
    MaterialApp(
      theme: platform == null ? null : ThemeData(platform: platform),
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(
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

  testWidgets('Sidebar shows settings topics for owners', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Git'), findsOneWidget);
    expect(find.text('Clone root'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
  });

  testWidgets('Sidebar hides Manage topic for non-owners', (tester) async {
    final state = AppState.test(
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Clone root'), findsOneWidget);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('Settings topic selection updates AppState', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Personalization'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 2);
  });

  testWidgets('Tapping Manage nav topic selects the accounts section', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Manage'));
    await tester.pumpAndSettle();

    // Manage is the last owner topic; its index must map to the accounts
    // section, not the clone-root section that precedes it.
    expect(state.settingsTopicIndex, 5);
  });

  testWidgets('Tapping Clone root nav topic selects the clone-root section', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Clone root'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 4);
  });

  testWidgets('About nav topic is shown for owners and non-owners', (
    tester,
  ) async {
    final owner = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    owner.setPage(MainPage.settings);
    await tester.pumpWidget(_buildWithState(owner));
    await _openDrawer(tester);

    expect(find.text('About'), findsOneWidget);

    final nonOwner = AppState.test(
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    nonOwner.setPage(MainPage.settings);
    await tester.pumpWidget(_buildWithState(nonOwner));
    await _openDrawer(tester);

    expect(find.text('About'), findsOneWidget);
  });

  testWidgets('Tapping About nav topic selects the about section', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 6);
  });

  testWidgets('Tapping Git nav topic selects the git section', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 3);
  });

  testWidgets('Tapping Servers nav topic selects the servers section', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 6);
  });

  testWidgets('Sidebar thread tiles do not show status tags', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('My thread'), findsOneWidget);
    expect(find.byType(ThreadTag), findsNothing);
  });

  testWidgets('Active thread expands its owning project', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('My thread'), findsOneWidget);
  });

  testWidgets('Active thread is highlighted instead of project card', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final projectContainer = find.ancestor(
      of: find.text('p'),
      matching: find.byType(AnimatedContainer),
    );
    final projectDeco =
        tester.widget<AnimatedContainer>(projectContainer).decoration
            as BoxDecoration?;
    expect(projectDeco, isNotNull);
    expect(projectDeco!.border, isNull);
    expect(projectDeco.color, isNull);

    final threadContainer = find
        .ancestor(of: find.text('My thread'), matching: find.byType(Container))
        .first;
    final threadDeco =
        tester.widget<Container>(threadContainer).decoration as BoxDecoration?;
    expect(threadDeco, isNotNull);
    expect(threadDeco!.border, isNotNull);

    final context = tester.element(find.text('My thread'));
    expect(threadDeco.border!.top.color, Theme.of(context).colorScheme.primary);
  });

  testWidgets('Project drag handle is only on the header', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final projectHeader = find.ancestor(
      of: find.text('p'),
      matching: find.byType(ListTile),
    );
    final projectDragHandle = find.ancestor(
      of: projectHeader,
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(projectDragHandle, findsOneWidget);

    final threadDragHandle = find.ancestor(
      of: find.text('My thread'),
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(threadDragHandle, findsNothing);
  });

  testWidgets('Projects start collapsed when no thread is active', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('My thread'), findsNothing);

    await tester.tap(find.text('p'));
    await tester.pumpAndSettle();

    expect(find.text('My thread'), findsOneWidget);
  });

  testWidgets('Sidebar shows project git branch', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
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
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('main'), findsOneWidget);
  });

  testWidgets('Sidebar renders long git branch without layout exception', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(
          id: 1,
          name: 'p',
          path: '/x',
          isRepo: true,
          gitBranch: 'feature/very-long-branch-name',
          createdAt: '',
          updatedAt: '',
        ),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.byType(ListTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift+click delete skips confirmation and removes thread', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    final delete = find.widgetWithIcon(IconButton, Icons.delete_outline);
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      find.text('Delete this thread? This cannot be undone.'),
      findsNothing,
    );
    expect(find.text('My thread'), findsNothing);
    expect(api.deletedThreadIds, contains('a'));
    expect(state.threads, isEmpty);
  });

  testWidgets('Click delete without shift shows confirmation', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final delete = find.widgetWithIcon(IconButton, Icons.delete_outline);
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(
      find.text('Delete this thread? This cannot be undone.'),
      findsOneWidget,
    );
  });

  testWidgets('User chip is a rounded pill', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final chip = find
        .ancestor(of: find.text('owner'), matching: find.byType(Container))
        .first;
    final deco = tester.widget<Container>(chip).decoration as BoxDecoration?;
    expect(deco, isNotNull);
    expect(deco!.borderRadius, BorderRadius.circular(16));
  });

  testWidgets('Expanded project threads are not in a nested scrollable', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    // The outer project list scrolls; threads render inline.
    expect(find.byType(ListView), findsNothing);
    expect(find.text('My thread'), findsOneWidget);
  });

  testWidgets('Tapping a project does not clear the active thread', (
    tester,
  ) async {
    final state = AppState.test(
      api: _FakeApiService(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
        Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(state.activeThreadId, 'a');
    expect(find.text('p2'), findsOneWidget);

    await tester.tap(find.text('p2'));
    await tester.pumpAndSettle();

    expect(state.activeThreadId, 'a');
    expect(state.activeProjectId, 1);
  });

  testWidgets('Project three-dot menu opens rename dialog', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final projectTile = find
        .ancestor(of: find.text('p'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: projectTile,
      matching: find.byIcon(Icons.more_vert),
    );
    expect(more, findsOneWidget);

    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(state.dialog, DialogKind.renameProject);
    expect(state.renameProjectId, 1);
    expect(state.renameInitialName, 'p');
  });

  testWidgets('Thread three-dot menu opens rename dialog', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final threadTile = find
        .ancestor(of: find.text('My thread'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: threadTile,
      matching: find.byIcon(Icons.more_vert),
    );
    expect(more, findsOneWidget);

    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(state.dialog, DialogKind.renameThread);
    expect(state.renameThreadId, 'a');
    expect(state.renameInitialName, 'My thread');
  });

  testWidgets('Project pin menu item is present and toggles pin', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );
    api.pinProjectReturns[1] = Project(
      id: 1,
      name: 'p',
      path: '/x',
      pinned: true,
      createdAt: '',
      updatedAt: '',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final projectTile = find
        .ancestor(of: find.text('p'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: projectTile,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Pin'), findsOneWidget);
    final pinIcon = tester.widget<Icon>(find.byIcon(Icons.push_pin).first);
    final primary = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).colorScheme.primary;
    expect(pinIcon.color, primary);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(api.pinnedProjectIds, contains(1));
    expect(state.projects.first.pinned, isTrue);

    // Reopen the menu and confirm it now reads "Unpin".
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Unpin'), findsOneWidget);
  });

  testWidgets('Project pin menu item sorts pinned projects to top', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'First',
          path: '/x',
          position: 0,
          createdAt: '',
          updatedAt: '',
        ),
        Project(
          id: 2,
          name: 'Second',
          path: '/y',
          position: 1,
          createdAt: '',
          updatedAt: '',
        ),
      ],
    );
    api.pinProjectReturns[2] = Project(
      id: 2,
      name: 'Second',
      path: '/y',
      position: 1,
      pinned: true,
      createdAt: '',
      updatedAt: '',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final secondProjectTile = find
        .ancestor(of: find.text('Second'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: secondProjectTile,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Pin'), findsOneWidget);
    final pinIcon = tester.widget<Icon>(find.byIcon(Icons.push_pin).first);
    final primary = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).colorScheme.primary;
    expect(pinIcon.color, primary);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(api.pinnedProjectIds, contains(2));
    // The pinned project should now be first in the list.
    final projectTiles = find.byType(ListTile);
    final firstTile = projectTiles.at(0);
    expect(
      find.descendant(of: firstTile, matching: find.text('Second')),
      findsOneWidget,
    );
    expect(state.projects.first.id, 2);
  });

  testWidgets('Thread pin menu item is present and toggles pin', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );
    api.pinThreadReturns['a'] = Thread(
      id: 'a',
      title: 'My thread',
      projectId: 1,
      model: '',
      permissionMode: 'normal',
      pinned: true,
      createdAt: '',
      updatedAt: '',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final threadTile = find
        .ancestor(of: find.text('My thread'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: threadTile,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(more);
    await tester.pumpAndSettle();

    expect(find.text('Pin'), findsOneWidget);
    final pinIcon = tester.widget<Icon>(find.byIcon(Icons.push_pin).first);
    final primary = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).colorScheme.primary;
    expect(pinIcon.color, primary);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    expect(api.pinnedThreadIds, contains('a'));
    expect(state.threads.first.pinned, isTrue);

    // Reopen the menu and confirm it now reads "Unpin".
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('Unpin'), findsOneWidget);
  });

  testWidgets('Project delete menu item shows confirmation', (tester) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'MyProject',
          path: '/x',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      threads: [],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    // Open the project's more-vert menu.
    final projectTile = find
        .ancestor(of: find.text('MyProject'), matching: find.byType(ListTile))
        .first;
    final more = find.descendant(
      of: projectTile,
      matching: find.byIcon(Icons.more_vert),
    );
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();

    // Tap "Delete project".
    expect(find.text('Delete project'), findsOneWidget);
    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    // Confirmation dialog should be visible.
    expect(find.textContaining('Remove "MyProject"'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('Confirm project delete removes it', (tester) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'MyProject',
          path: '/x',
          createdAt: '',
          updatedAt: '',
        ),
        Project(id: 2, name: 'Other', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    // Open the project's more-vert menu and tap delete.
    final projectTile = find
        .ancestor(of: find.text('MyProject'), matching: find.byType(ListTile))
        .first;
    await tester.tap(
      find.descendant(of: projectTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    // Confirm.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.deletedProjectIds, contains(1));
    expect(find.text('MyProject'), findsNothing);
    expect(state.projects, hasLength(1));
  });

  testWidgets('Shift+click project delete skips confirmation', (tester) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'MyProject',
          path: '/x',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      threads: [],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    // Open the project's more-vert menu and tap delete.
    final projectTile = find
        .ancestor(of: find.text('MyProject'), matching: find.byType(ListTile))
        .first;
    await tester.tap(
      find.descendant(of: projectTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    // No confirmation dialog should have appeared.
    expect(find.textContaining('Remove "MyProject"'), findsNothing);
    expect(api.deletedProjectIds, contains(1));
    expect(state.projects, isEmpty);
  });

  testWidgets('Cancel project delete does not remove it', (tester) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'MyProject',
          path: '/x',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      threads: [],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final projectTile = find
        .ancestor(of: find.text('MyProject'), matching: find.byType(ListTile))
        .first;
    await tester.tap(
      find.descendant(of: projectTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    // Tap Cancel.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Remove "MyProject"'), findsNothing);
    expect(api.deletedProjectIds, isEmpty);
    expect(find.text('MyProject'), findsOneWidget);
    expect(state.projects, hasLength(1));
  });

  testWidgets('Delete project with active thread clears selection', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(
          id: 1,
          name: 'MyProject',
          path: '/x',
          createdAt: '',
          updatedAt: '',
        ),
        Project(id: 2, name: 'Other', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    // Expand the project to see the thread.
    await tester.tap(find.text('MyProject'));
    await tester.pumpAndSettle();

    final projectTile = find
        .ancestor(of: find.text('MyProject'), matching: find.byType(ListTile))
        .first;
    await tester.tap(
      find.descendant(of: projectTile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete project'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(api.deletedProjectIds, contains(1));
    expect(find.text('MyProject'), findsNothing);
    expect(find.text('My thread'), findsNothing);
    expect(state.projects, hasLength(1));
    expect(state.activeProjectId, 2);
  });

  testWidgets('Connection status icon shows connected', (tester) async {
    final api = _FakeApiService()..healthOk = true;
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
    );
    await state.checkConnection();

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final chipRow = find.ancestor(
      of: find.text('owner'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: chipRow, matching: find.byIcon(Icons.cloud_done)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chipRow, matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('Connection status icon shows disconnected', (tester) async {
    final api = _FakeApiService()..healthOk = false;
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
    );
    await state.checkConnection();

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final chipRow = find.ancestor(
      of: find.text('owner'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: chipRow, matching: find.byIcon(Icons.cloud_off)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chipRow, matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );
    expect(find.text('Disconnected'), findsNothing);
  });

  testWidgets('Connection status icon shows checking', (tester) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
      connectionStatus: ConnectionStatus.checking,
    );

    await tester.pumpWidget(_buildWithState(state));
    // Use pump instead of pumpAndSettle to avoid timing out on the
    // CircularProgressIndicator in the checking state.
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffold.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final chipRow = find.ancestor(
      of: find.text('owner'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(
        of: chipRow,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chipRow, matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );
    expect(find.text('Checking connection\u2026'), findsNothing);
  });

  testWidgets('Pinned project shows a leading border', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(
          id: 1,
          name: 'Pinned project',
          path: '/x',
          pinned: true,
          createdAt: '',
          updatedAt: '',
        ),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final container = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.text('Pinned project'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    final border = decoration.border as Border?;
    expect(border, isNotNull);
    expect(border!.left, isNot(BorderSide.none));
    expect(border.left.width, 3);
  });

  testWidgets('Pinned thread shows a leading border', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'Pinned thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          pinned: true,
          createdAt: '',
          updatedAt: '',
        ),
        Thread(
          id: 'b',
          title: 'Active thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'b',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final container = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Pinned thread'),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    final border = decoration.border as Border?;
    expect(border, isNotNull);
    expect(border!.left, isNot(BorderSide.none));
    expect(border.left.width, 3);
  });

  testWidgets('Deleting a thread slides the tile out before removing it', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    final delete = find.widgetWithIcon(IconButton, Icons.delete_outline);
    expect(delete, findsOneWidget);
    await tester.tap(delete);

    await tester.pump(const Duration(milliseconds: 150));

    // The thread is still visible mid-slide and the backend call is delayed.
    expect(find.text('My thread'), findsOneWidget);
    expect(api.deletedThreadIds, isEmpty);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(api.deletedThreadIds, contains('a'));
    expect(state.threads, isEmpty);
    expect(find.text('My thread'), findsNothing);
  });

  testWidgets('Sidebar search filters projects and threads', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'alpha', path: '/x', createdAt: '', updatedAt: ''),
        Project(id: 2, name: 'beta', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'alpha task',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        Thread(
          id: 'b',
          title: 'beta task',
          projectId: 2,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final search = find.byKey(const Key('sidebar_search'));
    expect(search, findsOneWidget);

    await tester.enterText(search, 'beta task');
    await tester.pumpAndSettle();

    expect(find.text('beta'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('beta task'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('alpha task'),
      ),
      findsNothing,
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('Search shows no results when nothing matches', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.enterText(find.byKey(const Key('sidebar_search')), 'xyz');
    await tester.pumpAndSettle();

    expect(find.text('p'), findsNothing);
    expect(find.text('My thread'), findsNothing);
    expect(find.text('No threads found.'), findsOneWidget);
  });

  testWidgets('Active thread shows working status while sending', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ),
      sending: true,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Working'), findsOneWidget);
  });

  testWidgets('Active thread shows done status after assistant reply', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
      activeThreadDetail: ThreadDetail(
        thread: Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [
          Message(role: 'user', content: 'hello'),
          Message(role: 'assistant', content: 'done'),
        ],
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets(
    'Thread delete still completes if tile unmounts during animation',
    (tester) async {
      final api = _FakeApiService();
      final state = AppState.test(
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
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        threads: [
          Thread(
            id: 'keep',
            title: 'keep thread',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          Thread(
            id: 'trash',
            title: 'trash thread',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ],
        activeProjectId: 1,
        activeThreadId: 'keep',
      );

      api.listThreadsResult = [
        Thread(
          id: 'keep',
          title: 'keep thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ];

      await tester.pumpWidget(_buildWithState(state));
      await _openDrawer(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      final trashTile = find.ancestor(
        of: find.text('trash thread'),
        matching: find.byType(ListTile),
      );
      final delete = find.descendant(
        of: trashTile,
        matching: find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(delete, findsOneWidget);
      await tester.tap(delete);
      await tester.pump(const Duration(milliseconds: 50));

      // Filter the list while the delete animation is still running.
      // The 'trash' tile unmounts, but its delete callback must still fire.
      await tester.enterText(find.byKey(const Key('sidebar_search')), 'keep');
      await tester.pumpAndSettle();

      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(api.deletedThreadIds, contains('trash'));
      expect(find.text('trash thread'), findsNothing);
      expect(find.text('keep thread'), findsOneWidget);
    },
  );

  testWidgets('Ctrl+H focuses the sidebar search', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isTrue,
    );
  });

  testWidgets('Ctrl+K no longer focuses the sidebar search', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('⌘K focuses the sidebar search on macOS', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(
      _buildWithState(state, platform: TargetPlatform.macOS),
    );
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isTrue,
    );
  });

  testWidgets('Ctrl+H does not focus the sidebar search on macOS', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(
      _buildWithState(state, platform: TargetPlatform.macOS),
    );
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('Ctrl+Shift+H does not focus the sidebar search', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('⌘+Shift+K does not focus the sidebar search on macOS', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
    );

    await tester.pumpWidget(
      _buildWithState(state, platform: TargetPlatform.macOS),
    );
    await _openDrawer(tester);

    final searchField = find.byKey(const Key('sidebar_search'));
    final editableFinder = find.descendant(
      of: searchField,
      matching: find.byType(EditableText),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(
      tester.state<EditableTextState>(editableFinder).widget.focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('Projects header is compact and uppercase', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.byKey(const Key('sidebar_search')), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    expect(find.byIcon(Icons.create_new_folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
  });

  testWidgets('Project with more than five threads shows a Show more button', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 't1',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T10:00:00Z',
        ),
        Thread(
          id: 'b',
          title: 't2',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T09:00:00Z',
        ),
        Thread(
          id: 'c',
          title: 't3',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T08:00:00Z',
        ),
        Thread(
          id: 'd',
          title: 't4',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T07:00:00Z',
        ),
        Thread(
          id: 'e',
          title: 't5',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T06:00:00Z',
        ),
        Thread(
          id: 'f',
          title: 't6',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T05:00:00Z',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'b',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    for (final title in ['t1', 't2', 't3', 't4', 't5']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('t6'), findsNothing);
    expect(find.text('Show 1 more'), findsOneWidget);

    await tester.drag(find.text('t5'), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 1 more'));
    await tester.pumpAndSettle();

    expect(find.text('t6'), findsOneWidget);
    expect(find.text('Show 1 more'), findsNothing);
  });

  testWidgets('Active thread older than top five is hidden until Show more', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 't1',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T10:00:00Z',
        ),
        Thread(
          id: 'b',
          title: 't2',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T09:00:00Z',
        ),
        Thread(
          id: 'c',
          title: 't3',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T08:00:00Z',
        ),
        Thread(
          id: 'd',
          title: 't4',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T07:00:00Z',
        ),
        Thread(
          id: 'e',
          title: 't5',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T06:00:00Z',
        ),
        Thread(
          id: 'f',
          title: 't6',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T05:00:00Z',
        ),
        Thread(
          id: 'g',
          title: 't7',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T04:00:00Z',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'g',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    for (final title in ['t1', 't2', 't3', 't4', 't5']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('t6'), findsNothing);
    expect(find.text('t7'), findsNothing);
    expect(find.text('Show 2 more'), findsOneWidget);

    await tester.drag(find.text('t5'), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 2 more'));
    await tester.pumpAndSettle();

    for (final title in ['t1', 't2', 't3', 't4', 't5', 't6', 't7']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Show 2 more'), findsNothing);
  });

  testWidgets('Five or fewer threads show no Show more button', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 't1',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T10:00:00Z',
        ),
        Thread(
          id: 'b',
          title: 't2',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T09:00:00Z',
        ),
        Thread(
          id: 'c',
          title: 't3',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T08:00:00Z',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    for (final title in ['t1', 't2', 't3']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Show 1 more'), findsNothing);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('Search expands all matching threads', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'task one',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T10:00:00Z',
        ),
        Thread(
          id: 'b',
          title: 'task two',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T09:00:00Z',
        ),
        Thread(
          id: 'c',
          title: 'task three',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T08:00:00Z',
        ),
        Thread(
          id: 'd',
          title: 'task four',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T07:00:00Z',
        ),
        Thread(
          id: 'e',
          title: 'task five',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T06:00:00Z',
        ),
        Thread(
          id: 'f',
          title: 'task six',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '2026-08-29T05:00:00Z',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('task six'), findsNothing);
    expect(find.text('Show 1 more'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('sidebar_search')), 'task');
    await tester.pumpAndSettle();

    for (final title in [
      'task one',
      'task two',
      'task three',
      'task four',
      'task five',
      'task six',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Show 1 more'), findsNothing);
  });

  testWidgets('Sidebar shows the app title and version', (tester) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(
      find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Devinorium'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(Sidebar), matching: find.text('0.21.0')),
      findsOneWidget,
    );
  });

  group('Sidebar window controls', () {
    testWidgets('shows traffic lights on desktop', (tester) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux, useMaterial3: true),
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const Scaffold(
              drawer: Drawer(child: Sidebar()),
              body: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await _openDrawer(tester);

      expect(find.byKey(const Key('window_close_button')), findsOneWidget);
      expect(find.byKey(const Key('window_minimize_button')), findsOneWidget);
      expect(find.byKey(const Key('window_maximize_button')), findsOneWidget);
    });

    testWidgets('hides traffic lights on mobile', (tester) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS, useMaterial3: true),
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const Scaffold(
              drawer: Drawer(child: Sidebar()),
              body: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await _openDrawer(tester);

      expect(find.byKey(const Key('window_close_button')), findsNothing);
      expect(find.byKey(const Key('window_minimize_button')), findsNothing);
      expect(find.byKey(const Key('window_maximize_button')), findsNothing);
    });

    testWidgets('settings header still shows traffic lights on desktop', (
      tester,
    ) async {
      final state = AppState.test(
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );
      state.setPage(MainPage.settings);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux, useMaterial3: true),
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const Scaffold(
              drawer: Drawer(child: Sidebar()),
              body: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await _openDrawer(tester);

      expect(find.byKey(const Key('window_close_button')), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  testWidgets('Sidebar hides the app title on the settings page', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Devinorium'), findsNothing);
  });

  testWidgets('Expanding another project does not re-expand the active one', (
    tester,
  ) async {
    final api = _FakeApiService();
    api.listThreadsResult = [
      Thread(
        id: 'a',
        title: 'Active thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      ),
      Thread(
        id: 'b',
        title: 'Other thread',
        projectId: 2,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      ),
    ];

    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
        Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [...api.listThreadsResult],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Active thread'), findsOneWidget);
    expect(find.text('Other thread'), findsNothing);

    // Collapse the active project manually.
    await tester.tap(find.text('p1'));
    await tester.pumpAndSettle();

    expect(find.text('Active thread'), findsNothing);

    // Expand the other project.
    await tester.tap(find.text('p2'));
    await tester.pumpAndSettle();

    expect(find.text('Other thread'), findsOneWidget);
    expect(find.text('Active thread'), findsNothing);
  });

  testWidgets('Collapsed active project stays collapsed after a refresh', (
    tester,
  ) async {
    final api = _FakeApiService();
    api.listThreadsResult = [
      Thread(
        id: 'a',
        title: 'Active thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      ),
      Thread(
        id: 'b',
        title: 'Other thread',
        projectId: 2,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      ),
    ];

    final state = AppState.test(
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
      projects: [
        Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
        Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
      ],
      threads: [...api.listThreadsResult],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('p1'));
    await tester.pumpAndSettle();

    expect(find.text('Active thread'), findsNothing);

    await state.refreshRunningThreads();
    await tester.pumpAndSettle();

    expect(find.text('Active thread'), findsNothing);
  });

  testWidgets(
    'Selecting a project with no active thread expands only that one',
    (tester) async {
      final api = _FakeApiService();
      api.listThreadsResult = [
        Thread(
          id: 'b',
          title: 'Other thread',
          projectId: 2,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ];

      final state = AppState.test(
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
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
        ],
        threads: [...api.listThreadsResult],
      );

      await tester.pumpWidget(_buildWithState(state));
      await _openDrawer(tester);

      expect(find.text('Other thread'), findsNothing);

      await tester.tap(find.text('p2'));
      await tester.pumpAndSettle();

      expect(find.text('Other thread'), findsOneWidget);
    },
  );

  testWidgets('Sidebar title no longer shows the server version chip', (
    tester,
  ) async {
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      serverVersion: '0.31.0',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);
    await tester.pumpAndSettle();

    expect(find.text('0.31.0'), findsNothing);
  });
}
