import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/file_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

ApiService _serviceFor(MockClient mock) =>
    ApiService(client: ApiClient.withClient(mock));

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('FileViewer', () {
    testWidgets('renders text content', (tester) async {
      final content = FileContent(
        path: '/x.dart',
        mime: 'text/plain',
        size: 12,
        base64: 'aGVsbG8gd29ybGQ=',
        text: 'hello world',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileViewer(content: content)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('hello world'), findsOneWidget);
    });

    testWidgets('switches to diff tab when diff is present', (tester) async {
      final content = FileContent(
        path: '/x.dart',
        mime: 'text/plain',
        size: 12,
        base64: '',
        text: 'new text',
        diff: const FileDiff(
          path: '/x.dart',
          oldText: 'old text',
          newText: 'new text',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileViewer(content: content, initialShowDiff: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Content tab is selected initially.
      expect(find.textContaining('new text'), findsOneWidget);

      // Switch to Diff tab.
      await tester.tap(find.text('Diff'));
      await tester.pumpAndSettle();

      expect(find.textContaining('- old text'), findsOneWidget);
      expect(find.textContaining('+ new text'), findsOneWidget);
    });

    testWidgets('shows binary placeholder for non-text files', (tester) async {
      final content = FileContent(
        path: '/x.bin',
        mime: 'application/octet-stream',
        size: 1024,
        base64: 'AA==',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileViewer(content: content)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Binary file'), findsOneWidget);
      expect(find.textContaining('1.0 KB'), findsOneWidget);
    });

    testWidgets('shows empty content placeholder for empty files', (tester) async {
      final content = FileContent(
        path: '/x.dart',
        mime: 'text/plain',
        size: 0,
        base64: '',
        text: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileViewer(content: content)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('No content'), findsOneWidget);
    });

    testWidgets('truncates long content with a show-all control', (tester) async {
      final long = List.generate(2001, (i) => 'line $i').join('\n');
      final content = FileContent(
        path: '/big.txt',
        mime: 'text/plain',
        size: long.length,
        base64: base64Encode(utf8.encode(long)),
        text: long,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FileViewer(content: content)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('more lines not shown'), findsOneWidget);
      final showAll = find.text('Show all');
      expect(showAll, findsOneWidget);

      // Scroll the button into view before tapping it.
      await tester.ensureVisible(showAll);
      await tester.pumpAndSettle();
      await tester.tap(showAll);
      await tester.pumpAndSettle();

      expect(find.textContaining('line 2000'), findsOneWidget);
      expect(find.text('Show all'), findsNothing);
    });
  });

  group('FileViewerPage', () {
    testWidgets('shows loading indicator while the file loads', (tester) async {
      final completer = Completer<http.Response>();
      final mock = MockClient((req) => completer.future);
      final state = AppState(api: _serviceFor(mock));

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const FileViewerPage(path: 'foo.rs'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(_json({
        'path': '/foo.rs',
        'mime': 'text/plain',
        'size': 3,
        'base64': 'Zm9v',
        'text': 'foo',
        'diff': null,
      }));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('foo.rs'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget);
    });

    testWidgets('shows copy button for non-empty files', (tester) async {
      final mock = MockClient((req) async => _json({
            'path': '/foo.rs',
            'mime': 'text/plain',
            'size': 11,
            'base64': 'aGVsbG8gd29ybGQ=',
            'text': 'hello world',
            'diff': null,
          }));
      final state = AppState(api: _serviceFor(mock));

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const FileViewerPage(path: 'foo.rs'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

      // Tapping the copy button should not throw.
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();
    });

    testWidgets('hides copy button for empty files', (tester) async {
      final mock = MockClient((req) async => _json({
            'path': '/foo.rs',
            'mime': 'text/plain',
            'size': 0,
            'base64': '',
            'text': '',
            'diff': null,
          }));
      final state = AppState(api: _serviceFor(mock));

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const FileViewerPage(path: 'foo.rs'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.textContaining('No content'), findsOneWidget);
    });

    testWidgets('loads file content and shows the app bar title',
        (tester) async {
      final mock = MockClient((req) async {
        expect(req.url.path, '/api/files/content');
        expect(req.url.queryParameters['path'], 'foo.rs');
        expect(req.url.queryParameters['diff'], 'true');
        return _json({
          'path': '/projects/1/foo.rs',
          'mime': 'text/x-rust',
          'size': 4,
          'base64': 'aGVsbA==',
          'text': null,
          'diff': {
            'path': '/projects/1/foo.rs',
            'old_text': 'old',
            'new_text': 'new',
          },
        });
      });
      final state = AppState(api: _serviceFor(mock));

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const FileViewerPage(
              path: 'foo.rs',
              projectId: 1,
              gitStatus: 'modified',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('foo.rs'), findsOneWidget);
      expect(find.textContaining('+ new'), findsOneWidget);
    });

    testWidgets('shows error when readFile fails', (tester) async {
      final mock = MockClient((req) async => http.Response('nope', 500));
      final state = AppState(api: _serviceFor(mock));

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const FileViewerPage(path: 'foo.rs'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to load file'), findsOneWidget);
    });
  });
}
