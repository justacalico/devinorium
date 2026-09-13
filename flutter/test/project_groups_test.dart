import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/dialogs.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
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
  ) =>
      throw UnimplementedError();
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
  }) =>
      throw UnimplementedError();
}

class _FakeApiService extends ApiService {
  final groupAssignments = <int, int?>{};
  final deletedGroupIds = <int>[];
  final renamedGroups = <int, String>{};
  var nextGroupId = 100;
  var nextProjectId = 200;
  List<ProjectGroup> groupsResult = [];
  List<Project> projectsResult = [];
  Object? groupsError;

  _FakeApiService() : super(client: _ThrowingClient());

  @override
  Future<List<ProjectGroup>> listProjectGroups({int? limit, int? offset}) {
    if (groupsError != null) return Future.error(groupsError!);
    return Future.value([...groupsResult]);
  }

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) {
    final slice = projectsResult.skip(offset ?? 0);
    return Future.value(
      limit == null ? slice.toList() : slice.take(limit).toList(),
    );
  }

  @override
  Future<Project> createProject({required String name, required String path}) {
    final p = Project(
      id: nextProjectId++,
      name: name,
      path: path,
      createdAt: '',
      updatedAt: '',
    );
    projectsResult = [...projectsResult, p];
    return Future.value(p);
  }

  @override
  Future<ProjectGroup> createProjectGroup({
    required String name,
    List<int>? projectIds,
  }) {
    final group = ProjectGroup(
      id: nextGroupId++,
      name: name,
      position: groupsResult.length,
      createdAt: '',
    );
    groupsResult = [...groupsResult, group];
    for (final pid in projectIds ?? const <int>[]) {
      groupAssignments[pid] = group.id;
    }
    return Future.value(group);
  }

  @override
  Future<void> renameProjectGroup(int id, String name) {
    renamedGroups[id] = name;
    groupsResult = [
      for (final g in groupsResult)
        g.id == id ? g.copyWith(name: name) : g,
    ];
    return Future.value();
  }

  @override
  Future<void> deleteProjectGroup(int id) {
    deletedGroupIds.add(id);
    groupsResult = groupsResult.where((g) => g.id != id).toList();
    return Future.value();
  }

  @override
  Future<Project> setProjectGroup(int id, int? groupId) {
    groupAssignments[id] = groupId;
    return Future.value(
      Project(
        id: id,
        name: 'project $id',
        path: '/x',
        groupId: groupId,
        createdAt: '',
        updatedAt: '',
      ),
    );
  }

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value([]);

  @override
  Future<List<Thread>> listThreadsForProject(
    int id, {
    int? limit,
    int? offset,
  }) =>
      Future.value([]);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value([]);

  @override
  Future<List<String>> getThreadRuns() => Future.value([]);

  @override
  Future<bool> checkHealth() => Future.value(true);

  @override
  Future<GitRepoInfo> gitRepoStatus(
    int projectId, {
    bool force = false,
    String? threadId,
  }) =>
      Future.value(GitRepoInfo());
}

User _user() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

Project _project(int id, {int? groupId}) => Project(
  id: id,
  name: 'project-$id',
  path: '/x/$id',
  groupId: groupId,
  createdAt: '',
  updatedAt: '',
);

Widget _buildWithState(AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(
        home: Scaffold(
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

  test('setProjectGroup updates the project entry', () async {
    final api = _FakeApiService();
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1)],
    );

    await state.setProjectGroup(1, 7);

    expect(api.groupAssignments[1], 7);
    expect(state.projects.single.groupId, 7);
  });

  test('createProjectGroup adds the group and assigns pending project', () async {
    final api = _FakeApiService();
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1)],
    );

    state.openNewProjectGroupDialog(projectId: 1);
    expect(state.dialog, DialogKind.newProjectGroup);

    await state.createProjectGroup('facebook');

    expect(state.projectGroups.single.name, 'facebook');
    expect(state.projects.single.groupId, state.projectGroups.single.id);
    expect(state.dialog, DialogKind.none);
  });

  test('deleteProjectGroup ungroups projects and clears selection', () async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1, groupId: 5), _project(2)],
      projectGroups: api.groupsResult,
      selectedProjectGroupId: 5,
    );

    await state.deleteProjectGroup(5);

    expect(api.deletedGroupIds, [5]);
    expect(state.projectGroups, isEmpty);
    expect(state.selectedProjectGroupId, isNull);
    expect(state.projects[0].groupId, isNull);
  });

  test('selectProjectGroup sets and clears the filter', () {
    final state = AppState.test(user: _user());

    state.selectProjectGroup(3);
    expect(state.selectedProjectGroupId, 3);

    state.selectProjectGroup(null);
    expect(state.selectedProjectGroupId, isNull);
  });

  testWidgets('group filter dropdown defaults to All and filters projects', (
    tester,
  ) async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1, groupId: 5), _project(2)],
      projectGroups: api.groupsResult,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    // Default shows every project.
    expect(find.text('project-1'), findsOneWidget);
    expect(find.text('project-2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('group_filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group_filter_5')));
    await tester.pumpAndSettle();

    expect(state.selectedProjectGroupId, 5);
    expect(find.text('project-1'), findsOneWidget);
    expect(find.text('project-2'), findsNothing);
  });

  testWidgets('selecting All from the filter restores every project', (
    tester,
  ) async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1, groupId: 5), _project(2)],
      projectGroups: api.groupsResult,
      selectedProjectGroupId: 5,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('project-2'), findsNothing);

    await tester.tap(find.byKey(const Key('group_filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group_filter_all')));
    await tester.pumpAndSettle();

    expect(state.selectedProjectGroupId, isNull);
    expect(find.text('project-1'), findsOneWidget);
    expect(find.text('project-2'), findsOneWidget);
  });

  testWidgets('project options menu assigns a group', (tester) async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1)],
      projectGroups: api.groupsResult,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('facebook'));
    await tester.pumpAndSettle();

    expect(api.groupAssignments[1], 5);
    expect(state.projects.single.groupId, 5);
  });

  testWidgets('new group dialog creates a group for the project', (
    tester,
  ) async {
    final api = _FakeApiService();
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1)],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(children: [Sidebar(), DialogLayer()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    state.openNewProjectGroupDialog(projectId: 1);
    await tester.pumpAndSettle();

    expect(state.dialog, DialogKind.newProjectGroup);

    await tester.enterText(
      find.byKey(const Key('new_group_name')),
      'facebook',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_group_create')));
    await tester.pumpAndSettle();

    expect(state.projectGroups.single.name, 'facebook');
    expect(state.projects.single.groupId, state.projectGroups.single.id);
    expect(state.dialog, DialogKind.none);
  });

  testWidgets('manage groups dialog renames and deletes groups', (
    tester,
  ) async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: [_project(1, groupId: 5)],
      projectGroups: api.groupsResult,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(children: [Sidebar(), DialogLayer()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    state.openManageProjectGroupsDialog();
    await tester.pumpAndSettle();

    final dialogCard = find.byWidgetPredicate(
      (w) => w is Card && w.elevation == 3,
    );
    expect(
      find.descendant(of: dialogCard, matching: find.text('facebook')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogCard, matching: find.text('1 project')),
      findsOneWidget,
    );

    // Rename.
    await tester.tap(find.byKey(const Key('rename_group_5')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'New name',
      ),
      'meta',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.renamedGroups[5], 'meta');
    expect(state.projectGroups.single.name, 'meta');
    expect(state.dialog, DialogKind.manageProjectGroups);

    // Delete with confirmation.
    await tester.tap(find.byKey(const Key('delete_group_5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.deletedGroupIds, [5]);
    expect(state.projectGroups, isEmpty);
    expect(state.projects.single.groupId, isNull);
  });

  test('group load failure keeps existing state', () async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ]
      ..groupsError = ApiException('boom', 500);
    final state = AppState.test(
      api: api,
      user: _user(),
      projectGroups: api.groupsResult,
      selectedProjectGroupId: 5,
    );

    await state.loadProjectGroups();

    expect(state.projectGroupsUnsupported, isFalse);
    expect(state.projectGroups.single.id, 5);
    expect(state.selectedProjectGroupId, 5);
  });

  testWidgets('a backend without the route hides the group UI', (
    tester,
  ) async {
    final api = _FakeApiService()
      ..projectsResult = [_project(1)]
      ..groupsError = ApiException('Not Found', 404);
    final state = AppState.test(
      api: api,
      user: _user(),
      projects: api.projectsResult,
    );

    await state.loadProjects();

    expect(state.projectGroupsUnsupported, isTrue);
    expect(state.projectGroups, isEmpty);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.byKey(const Key('group_filter')), findsNothing);

    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    expect(find.text('Group'), findsNothing);
  });

  test('createProject assigns the selected group', () async {
    final api = _FakeApiService()
      ..groupsResult = [
        ProjectGroup(id: 5, name: 'facebook', position: 0, createdAt: ''),
      ];
    final state = AppState.test(
      api: api,
      user: _user(),
      projectGroups: api.groupsResult,
    );

    state.selectProjectGroup(5);
    await state.createProject(name: 'new', path: '/new');

    final created = state.projects.single;
    expect(api.groupAssignments[created.id], 5);
    expect(created.groupId, 5);
  });

  test('new group opened from manage returns to the manage dialog', () async {
    final api = _FakeApiService();
    final state = AppState.test(api: api, user: _user());

    state.openManageProjectGroupsDialog();
    state.openNewProjectGroupDialog(fromManage: true);
    await state.createProjectGroup('facebook');

    expect(state.projectGroups.single.name, 'facebook');
    expect(state.dialog, DialogKind.manageProjectGroups);
  });
}
