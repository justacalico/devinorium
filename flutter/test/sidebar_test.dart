import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    List<({String filename, String mime, Uint8List bytes})>? attachments,
  }) => throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  final deletedThreadIds = <String>[];

  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<void> deleteThread(String id) {
    deletedThreadIds.add(id);
    return Future.value();
  }

  @override
  Future<List<Thread>> listThreads() => Future.value([]);

  @override
  Future<List<ThreadGroup>> listThreadGroups() => Future.value([]);

  @override
  Future<GitRepoInfo> gitRepoStatus(int projectId) =>
      Future.value(GitRepoInfo());

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle'});
}

Widget _buildWithState(AppState state) => MaterialApp(
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
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
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
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
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

    expect(state.settingsTopicIndex, 3);
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
    final projectDeco = tester.widget<AnimatedContainer>(projectContainer).decoration
        as BoxDecoration?;
    expect(projectDeco, isNotNull);
    expect(projectDeco!.border, isNull);
    expect(projectDeco.color, isNull);

    final threadContainer = find.ancestor(
      of: find.text('My thread'),
      matching: find.byType(Container),
    ).first;
    final threadDeco = tester.widget<Container>(threadContainer).decoration
        as BoxDecoration?;
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
        .ancestor(
          of: find.text('owner'),
          matching: find.byType(Container),
        )
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

    final projectTile = find.ancestor(
      of: find.text('p'),
      matching: find.byType(ListTile),
    ).first;
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

    final threadTile = find.ancestor(
      of: find.text('My thread'),
      matching: find.byType(ListTile),
    ).first;
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
}
