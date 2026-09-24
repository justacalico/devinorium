import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/editor/file_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

Widget _buildWithState(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: FileEditor())),
    );

void main() {
  final project =
      Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '');

  AppState stateFor(Map<String, Object?> fileJson) {
    final client = ApiClient.withClient(
      MockClient((req) async => _json(fileJson)),
    );
    return AppState.test(
      api: ApiService(client: client),
      projects: [project],
      activeProjectId: 1,
    );
  }

  group('FileEditor', () {
    testWidgets('renders image files instead of the binary placeholder',
        (tester) async {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final state = stateFor({
        'path': '/x/pic.png',
        'mime': 'image/png',
        'size': 68,
        'base64': png,
        'text': null,
        'sha256': 'abc',
      });
      await state.openEditorFile('pic.png');

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('binary file'), findsNothing);
    });

    testWidgets('keeps the binary placeholder for non-image files',
        (tester) async {
      final state = stateFor({
        'path': '/x/a.bin',
        'mime': 'application/octet-stream',
        'size': 4,
        'base64': 'AAAAAA==',
        'text': null,
        'sha256': 'abc',
      });
      await state.openEditorFile('a.bin');

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('binary file'), findsOneWidget);
    });
  });
}
