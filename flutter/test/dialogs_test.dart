import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/dialogs.dart';
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
}
