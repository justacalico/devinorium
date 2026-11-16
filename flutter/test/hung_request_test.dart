import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
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

/// A client whose responses can be held open indefinitely, like requests
/// caught on a half-dead socket when wifi drops mid-flight.
class _FlakyHttp {
  bool hang = false;
  http.Response Function(http.BaseRequest req)? responder;

  late final ApiClient client = ApiClient.withClient(
    MockClient((req) async {
      if (hang) return Completer<http.Response>().future;
      return responder?.call(req) ?? _json(404, {'error': 'no response set'});
    }),
  );
}

ApiService _api(
  _FlakyHttp http, {
  Duration timeout = const Duration(milliseconds: 50),
}) => ApiService(
  client: http.client,
  requestTimeout: timeout,
  fileContentTimeout: timeout,
);

AppState _state(ApiService api) => AppState.test(
  api: api,
  projects: [
    Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
  ],
  activeProjectId: 1,
);

void main() {
  test('files panel clears loading and reloads after a hung request', () async {
    final http = _FlakyHttp()..hang = true;
    final state = _state(_api(http));

    await state.openFilesPanel();
    expect(state.filesTreeRoot.isLoading, isFalse);
    expect(state.filesError, isNotEmpty);

    http.hang = false;
    http.responder = (_) => _json(200, [
      {'name': 'a.dart', 'is_dir': false, 'size': 3},
    ]);

    await state.reloadFiles();
    expect(state.filesError, isEmpty);
    expect(state.filesTreeRoot.children.map((n) => n.name), contains('a.dart'));
  });

  testWidgets('FilesPanel retries a failed tree load on mount', (tester) async {
    final http = _FlakyHttp();
    var listCalls = 0;
    http.responder = (_) {
      listCalls++;
      return _json(500, {'error': 'down'});
    };
    final state = _state(_api(http));

    await state.openFilesPanel();
    expect(state.filesError, isNotEmpty);
    expect(listCalls, 1);

    http.responder = (_) {
      listCalls++;
      return _json(200, [
        {'name': 'a.dart', 'is_dir': false, 'size': 3},
      ]);
    };

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Material(
              type: MaterialType.transparency,
              child: FilesPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(listCalls, 2);
    expect(find.text('a.dart'), findsOneWidget);
  });

  test('openThread clears the opening flag after a hung fetch', () async {
    final http = _FlakyHttp()..hang = true;
    final state = _state(_api(http));

    await state.openThread('t1');
    expect(state.activeThreadLoading, isFalse);
    expect(state.globalError, isNotEmpty);

    // The next open must issue fresh requests instead of no-oping behind a
    // stuck flag.
    var getCalls = 0;
    http.hang = false;
    http.responder = (_) {
      getCalls++;
      return _json(500, {'error': 'still down'});
    };
    await state.openThread('t1');
    expect(getCalls, greaterThan(0));
    expect(state.activeThreadLoading, isFalse);
  });

  test('editor tab shows an error and reloads after a hung read', () async {
    final http = _FlakyHttp()..hang = true;
    final state = _state(_api(http));

    await state.openEditorFile('a.dart');
    final tab = state.activeEditorTab!;
    expect(tab.loading, isFalse);
    expect(tab.error, isNotNull);

    http.hang = false;
    http.responder = (_) => _json(200, {
      'path': 'a.dart',
      'mime': 'text/plain',
      'size': 1,
      'base64': '',
      'text': 'x',
      'sha256': 'abc',
    });

    await state.reloadEditorTab('a.dart');
    expect(state.activeEditorTab!.error, isNull);
    expect(state.activeEditorTab!.loading, isFalse);
    expect(state.activeEditorTab!.text, 'x');
  });
}
