import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/views/folder_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

Future<void> _pumpDialog(
  WidgetTester tester,
  ApiClient client, {
  String? initialPath,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _PickerLauncher(client: client, initialPath: initialPath),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _PickerLauncher extends StatefulWidget {
  final ApiClient client;
  final String? initialPath;

  const _PickerLauncher({required this.client, this.initialPath});

  @override
  State<_PickerLauncher> createState() => _PickerLauncherState();
}

class _PickerLauncherState extends State<_PickerLauncher> {
  String? _result;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final picked = await showFolderPickerDialog(
          context,
          api: ApiService(client: widget.client),
          initialPath: widget.initialPath,
        );
        setState(() => _result = picked);
      },
      child: Text(_result ?? 'open'),
    );
  }
}

void main() {
  testWidgets('selects home as ~', (tester) async {
    final client = _clientFor([_json(200, [])]);
    await _pumpDialog(tester, client);

    await tester.tap(find.text('Select current folder'));
    await tester.pumpAndSettle();

    expect(find.text('~'), findsOneWidget);
  });

  testWidgets('navigates into subfolder and returns ~/sub', (tester) async {
    final client = _clientFor([
      _json(200, [
        {'name': 'clones', 'is_dir': true, 'size': 0},
      ]),
      _json(200, []),
    ]);
    await _pumpDialog(tester, client);

    await tester.tap(find.text('clones'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select current folder'));
    await tester.pumpAndSettle();

    expect(find.text('~/clones'), findsOneWidget);
  });

  testWidgets('navigates absolute path and returns /srv', (tester) async {
    final client = _clientFor([
      _json(200, []),
      _json(200, [
        {'name': 'srv', 'is_dir': true, 'size': 0},
      ]),
      _json(200, []),
    ]);
    await _pumpDialog(tester, client);

    final pathField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Path',
    );
    await tester.enterText(pathField, '/');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select current folder'));
    await tester.pumpAndSettle();

    expect(find.text('/srv'), findsOneWidget);
  });

  testWidgets('uses initialPath', (tester) async {
    final client = _clientFor([
      _json(200, [
        {'name': 'clones', 'is_dir': true, 'size': 0},
      ]),
    ]);
    await _pumpDialog(tester, client, initialPath: '~/clones');

    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('clones')),
      findsOneWidget,
    );
  });

  testWidgets('cancelling returns null', (tester) async {
    final client = _clientFor([_json(200, [])]);
    await _pumpDialog(tester, client);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
