import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/semantic_colors.dart';
import 'package:devinorium_frontend/views/file_viewer.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
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

Widget _buildWithState(AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: Material(type: MaterialType.transparency, child: FilesPanel()),
        ),
      ),
    );

AppState _stateWithEntries(List<DirEntry> entries) {
  final state = AppState.test(
    projects: [
      Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
    ],
    activeProjectId: 1,
  );
  state.setFilesEntries(entries);
  return state;
}

void main() {
  group('FilesPanel file icons', () {
    testWidgets('shows folder icon for directories', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([DirEntry(name: 'src', isDir: true, size: 0)]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('shows package icon for pubspec.yaml', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'pubspec.yaml', isDir: false, size: 500),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    });

    testWidgets('shows html icon for .html files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'index.html', isDir: false, size: 100),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.html_outlined), findsOneWidget);
    });

    testWidgets('shows code icon for .dart files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'main.dart', isDir: false, size: 200),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.code), findsOneWidget);
    });

    testWidgets('shows image icon for .png files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'logo.png', isDir: false, size: 4096),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('shows archive icon for .zip files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'archive.zip', isDir: false, size: 50000),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.folder_zip_outlined), findsOneWidget);
    });

    testWidgets('shows terminal icon for .sh files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'build.sh', isDir: false, size: 200),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });

    testWidgets('shows default file icon for unknown extensions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'data.xyz', isDir: false, size: 100),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    });

    testWidgets('shows readme icon for README.md', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'README.md', isDir: false, size: 1000),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
    });

    testWidgets('shows git icon for .gitignore', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: '.gitignore', isDir: false, size: 50),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.merge_type_outlined), findsOneWidget);
    });

    testWidgets('shows database icon for .sql files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'schema.sql', isDir: false, size: 800),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.storage_outlined), findsOneWidget);
    });

    testWidgets('shows pdf icon for .pdf files', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(name: 'doc.pdf', isDir: false, size: 5000),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    });

    testWidgets('highlights modified files in the title color', (tester) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(
              name: 'main.dart',
              isDir: false,
              size: 200,
              gitStatus: 'modified',
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('main.dart'));
      final semantic = SemanticColors.fallback(Brightness.light);
      expect(text.style?.color, semantic.warning);
    });

    testWidgets('highlights folders containing changes in the title color', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWithState(
          _stateWithEntries([
            DirEntry(
              name: 'src',
              isDir: true,
              size: 0,
              gitStatus: 'descendant',
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('src'));
      final semantic = SemanticColors.fallback(Brightness.light);
      expect(text.style?.color, semantic.warning);
    });

    testWidgets('tapping a file opens the file viewer', (tester) async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'path': '/x/main.dart',
            'mime': 'text/x-dart',
            'size': 16,
            'base64': 'cHJpbnQoJ2hleScp',
            'text': "print('hey')",
            'diff': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        api: ApiService(client: ApiClient.withClient(mock)),
      );
      state.setFilesEntries([
        DirEntry(
          name: 'main.dart',
          isDir: false,
          size: 16,
          gitStatus: 'modified',
        ),
      ]);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();

      expect(find.byType(FileViewerPage), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.textContaining("print('hey')"), findsOneWidget);
    });
  });

  group('FilesPanel tree', () {
    testWidgets('expands a folder when tapped', (tester) async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {'name': 'src', 'is_dir': true, 'size': 0},
            ]),
            _json(200, [
              {'name': 'main.dart', 'is_dir': false, 'size': 200},
            ]),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      await tester.pumpWidget(_buildWithState(base));
      await tester.pumpAndSettle();

      expect(find.text('src'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
    });

    testWidgets('collapses an expanded folder when tapped', (tester) async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {'name': 'src', 'is_dir': true, 'size': 0},
            ]),
            _json(200, [
              {'name': 'main.dart', 'is_dir': false, 'size': 200},
            ]),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      final dir = base.filesTreeRoot.children.first;
      await base.toggleFilesFolder(dir);
      await tester.pumpWidget(_buildWithState(base));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsNothing);
    });

    testWidgets('shows empty message for an empty expanded folder', (
      tester,
    ) async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {'name': 'src', 'is_dir': true, 'size': 0},
            ]),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      final dir = base.filesTreeRoot.children.first;
      await base.toggleFilesFolder(dir);
      await tester.pumpWidget(_buildWithState(base));
      await tester.pumpAndSettle();

      expect(find.text('Empty folder'), findsOneWidget);
    });
  });

  group('FilesPanel editor thread gate', () {
    testWidgets('shows select thread placeholder when no thread in editor', (
      tester,
    ) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );
      state.setFilesEntries([
        DirEntry(name: 'main.dart', isDir: false, size: 200),
      ]);
      state.setAppMode(AppMode.editor);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Select or create a thread'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    });

    testWidgets('shows files in editor when a thread is active', (
      tester,
    ) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        activeThreadId: 'a',
      );
      state.setFilesEntries([
        DirEntry(name: 'main.dart', isDir: false, size: 200),
      ]);
      state.setAppMode(AppMode.editor);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('Select or create a thread'), findsNothing);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsOneWidget);
    });

    testWidgets('shows project placeholder in editor without project', (
      tester,
    ) async {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Select a project first'), findsOneWidget);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    });

    testWidgets('shows files in agents mode without active thread', (
      tester,
    ) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );
      state.setFilesEntries([
        DirEntry(name: 'main.dart', isDir: false, size: 200),
      ]);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('Select or create a thread'), findsNothing);
    });

    testWidgets('shows project placeholder in agents mode without project', (
      tester,
    ) async {
      final state = AppState.test();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Select a project first'), findsOneWidget);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    });
  });

  group('FilesPanel worktree scope', () {
    ThreadDetail detail({String? worktree, String envMode = 'local'}) =>
        ThreadDetail(
          thread: Thread(
            id: 't1',
            title: 't',
            projectId: 1,
            model: 'm',
            permissionMode: 'normal',
            envMode: envMode,
            worktreePath: worktree,
            createdAt: '',
            updatedAt: '',
          ),
          messages: const [],
        );

    testWidgets('follows the thread worktree and shows a marker', (
      tester,
    ) async {
      final requests = <Uri>[];
      var worktree = false;
      final mock = MockClient((req) async {
        requests.add(req.url);
        if (req.url.path == '/api/files') {
          return _json(200, [
            {
              'name': worktree ? 'wt.txt' : 'proj.txt',
              'is_dir': false,
              'size': 1,
            },
          ]);
        }
        if (req.url.path == '/api/threads/t1' && req.method == 'GET') {
          return _json(200, {
            'thread': {
              'id': 't1',
              'title': 't',
              'project_id': 1,
              'model': 'm',
              'permission_mode': 'normal',
              'env_mode': worktree ? 'worktree' : 'local',
              'worktree_path': worktree ? '/wt' : null,
              'created_at': '',
              'updated_at': '',
            },
            'messages': [],
          });
        }
        if (req.url.path == '/api/threads/runs') {
          return _json(200, {'running_ids': []});
        }
        if (req.url.path.endsWith('/messages')) {
          return _json(200, {'messages': []});
        }
        return _json(200, req.method == 'GET' ? [] : <String, dynamic>{});
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: detail(),
      );
      await state.openFilesPanel();
      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(state.filesScopeKey, 'project:1');
      expect(find.text('proj.txt'), findsOneWidget);
      expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);

      // The thread's run created a worktree; the panel must follow it.
      worktree = true;
      await state.setThreadGit('t1', worktreePath: '/wt');
      await state.setThreadEnvMode('t1', 'worktree');
      await tester.pumpAndSettle();

      expect(state.filesScopeKey, 'worktree:/wt');
      expect(find.byIcon(Icons.folder_copy_outlined), findsOneWidget);
      expect(find.text('wt.txt'), findsOneWidget);
      final fileReqs = requests.where((u) => u.path == '/api/files').toList();
      expect(fileReqs.length, greaterThanOrEqualTo(2));
      expect(fileReqs.last.queryParameters['thread_id'], 't1');
    });
  });
}
