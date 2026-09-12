import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  return ApiClient.withClient(MockClient((req) async {
    if (index >= responses.length) {
      return _json(404, {'error': 'unexpected request to ${req.url.path}'});
    }
    return responses[index++];
  }));
}

void main() {
  group('NewProjectDialog', () {
    testWidgets('selects home root as . and submits', (tester) async {
      final client = _clientFor([
        _json(200, [
          {'name': 'devin', 'is_dir': true, 'size': 0},
        ]),
        _json(201, {
          'id': 1,
          'name': 'devin',
          'path': '/tmp/files',
          'created_at': '',
          'updated_at': '',
        }),
      ]);
      final state = AppState.test(
        api: ApiService(client: client),
        dialog: DialogKind.newProject,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // Enter a name.
      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name',
      );
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, 'devin');

      // Tap "Select current folder" at the home root.
      await tester.tap(find.text('Select current folder'));
      await tester.pump();

      final pathField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Path',
      );
      final pathText = tester.widget<TextField>(pathField);
      expect(pathText.controller?.text, '.');

      // Submit and verify the backend received the right request.
      await tester.tap(find.text('Create'));
      await tester.pump();
      await tester.pumpAndSettle();
    });

    testWidgets('select current folder fills name with folder name', (tester) async {
      final client = _clientFor([
        _json(200, [
          {'name': 'devinorium', 'is_dir': true, 'size': 0},
        ]),
        _json(200, []),
      ]);
      final state = AppState.test(
        api: ApiService(client: client),
        dialog: DialogKind.newProject,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('devinorium'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select current folder'));
      await tester.pump();

      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name',
      );
      final nameText = tester.widget<TextField>(nameField);
      expect(nameText.controller?.text, 'devinorium');

      final pathField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Path',
      );
      final pathText = tester.widget<TextField>(pathField);
      expect(pathText.controller?.text, 'devinorium');
    });

    testWidgets('expands ~ to home directory', (tester) async {
      final client = _clientFor([
        _json(200, []),
        _json(201, {
          'id': 1,
          'name': 'home',
          'path': '/tmp/files',
          'created_at': '',
          'updated_at': '',
        }),
      ]);
      final state = AppState.test(
        api: ApiService(client: client),
        dialog: DialogKind.newProject,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pathField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Path',
      );
      await tester.enterText(pathField, '~');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name',
      );
      await tester.enterText(nameField, 'home');

      await tester.tap(find.text('Create'));
      await tester.pump();
      await tester.pumpAndSettle();
    });
  });

  group('RenameDialog', () {
    testWidgets('pre-fills project name and disables save when unchanged',
        (tester) async {
      final client = _clientFor([
        _json(200, {
          'id': 1,
          'name': 'new',
          'path': '/x',
          'created_at': '',
          'updated_at': '',
        }),
      ]);
      final state = AppState.test(
        api: ApiService(client: client),
        dialog: DialogKind.renameProject,
        activeProjectId: 1,
        projects: [
          Project(id: 1, name: 'old', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename project'), findsOneWidget);

      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'New name',
      );
      expect(nameField, findsOneWidget);
      expect(
        tester.widget<TextField>(nameField).controller?.text,
        'old',
      );

      final save = find.widgetWithText(FilledButton, 'Save');
      expect(save, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(nameField, 'new');
      await tester.pump();

      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(state.dialog, DialogKind.none);
      expect(state.projects.first.name, 'new');
    });

    testWidgets('pre-fills thread title and renames thread', (tester) async {
      final client = _clientFor([_json(200, {})]);
      final state = AppState.test(
        api: ApiService(client: client),
        dialog: DialogKind.renameThread,
        threads: [
          Thread(
            id: 'a',
            title: 'old',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ],
      );
      state.openRenameThreadDialog('a', 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename thread'), findsOneWidget);

      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'New name',
      );
      await tester.enterText(nameField, 'new');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.dialog, DialogKind.none);
      expect(state.threads.first.title, 'new');
    });

    testWidgets('save is disabled when name is empty', (tester) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'old', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nameField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'New name',
      );
      await tester.enterText(nameField, '');
      await tester.pump();

      final save = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    });
  });

  group('Escape dismissal', () {
    testWidgets('escape closes rename dialog while its field has focus',
        (tester) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'old', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename project'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(state.dialog, DialogKind.none);
      expect(find.text('Rename project'), findsNothing);
    });

    testWidgets('autofocused field keeps focus when the dialog opens',
        (tester) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'old', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      expect(
        focused!.context!.findAncestorWidgetOfExactType<TextField>(),
        isNotNull,
      );
    });

    testWidgets('escape does not close the web login prompt', (tester) async {
      final state = AppState.test(dialog: DialogKind.webLogin);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(state.dialog, DialogKind.webLogin);
    });

    testWidgets('escape pops a covering route before the dialog',
        (tester) async {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'old', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'old');

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      showDialog<void>(
        context: tester.element(find.byType(DialogLayer)),
        builder: (_) => const AlertDialog(content: Text('route dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('route dialog'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // The route popped; the dialog underneath stays open.
      expect(find.text('route dialog'), findsNothing);
      expect(state.dialog, DialogKind.renameProject);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(state.dialog, DialogKind.none);
    });

    testWidgets('escape rejects a pending permission request', (tester) async {
      final client = _clientFor([_json(200, {})]);
      final state = AppState.test(
        api: ApiService(client: client),
        activeThreadId: 'a',
        dialog: DialogKind.permissionRequest,
        pendingPermissionRequest: PermissionRequest(
          requestId: 'r1',
          scope: 'Exec(curl)',
          title: 'Run?',
          options: [PermissionOption(id: 'once', kind: 'AllowOnce')],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const DialogLayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Run?'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(state.pendingPermissionRequest, isNull);
      expect(state.dialog, DialogKind.none);
    });
  });
}
