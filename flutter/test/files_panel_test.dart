import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: Scaffold(
          body: Material(
            type: MaterialType.transparency,
            child: FilesPanel(),
          ),
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
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'src', isDir: true, size: 0)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('shows package icon for pubspec.yaml', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'pubspec.yaml', isDir: false, size: 500)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    });

    testWidgets('shows html icon for .html files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'index.html', isDir: false, size: 100)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.html_outlined), findsOneWidget);
    });

    testWidgets('shows code icon for .dart files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'main.dart', isDir: false, size: 200)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.code), findsOneWidget);
    });

    testWidgets('shows image icon for .png files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'logo.png', isDir: false, size: 4096)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('shows archive icon for .zip files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'archive.zip', isDir: false, size: 50000)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.folder_zip_outlined), findsOneWidget);
    });

    testWidgets('shows terminal icon for .sh files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'build.sh', isDir: false, size: 200)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });

    testWidgets('shows default file icon for unknown extensions', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'data.xyz', isDir: false, size: 100)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    });

    testWidgets('shows readme icon for README.md', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'README.md', isDir: false, size: 1000)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
    });

    testWidgets('shows git icon for .gitignore', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: '.gitignore', isDir: false, size: 50)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.merge_type_outlined), findsOneWidget);
    });

    testWidgets('shows database icon for .sql files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'schema.sql', isDir: false, size: 800)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.storage_outlined), findsOneWidget);
    });

    testWidgets('shows pdf icon for .pdf files', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([DirEntry(name: 'doc.pdf', isDir: false, size: 5000)]),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    });

    testWidgets('highlights modified files in the title color', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([
          DirEntry(
            name: 'main.dart',
            isDir: false,
            size: 200,
            gitStatus: 'modified',
          ),
        ]),
      ));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('main.dart'));
      expect(text.style?.color, Colors.orange);
    });

    testWidgets('highlights folders containing changes in the title color', (tester) async {
      await tester.pumpWidget(_buildWithState(
        _stateWithEntries([
          DirEntry(
            name: 'src',
            isDir: true,
            size: 0,
            gitStatus: 'descendant',
          ),
        ]),
      ));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('src'));
      expect(text.style?.color, Colors.orange);
    });
  });
}
