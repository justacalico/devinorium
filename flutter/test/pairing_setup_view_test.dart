import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/pairing_setup_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TestAppState extends AppState {
  _TestAppState() : super.test();

  PairingResponse? imported;

  @override
  Future<void> completePairing(PairingResponse pairing) async {
    imported = pairing;
  }
}

void main() {
  group('PairingSetupView', () {
    testWidgets('imports a valid pairing file', (tester) async {
      final state = _TestAppState();
      const content =
          '{"ok":true,"token":"abc123","username":"owner","server_url":"http://localhost:7878"}';

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => utf8.encode(content),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(state.imported, isNotNull);
      expect(state.imported!.token, 'abc123');
      expect(state.imported!.username, 'owner');
      expect(state.imported!.serverUrl, 'http://localhost:7878');
    });

    testWidgets('shows an error for invalid json', (tester) async {
      final state = _TestAppState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => utf8.encode('not-json'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('无法解析文件'), findsOneWidget);
      expect(state.imported, isNull);
    });

    testWidgets('shows an error when the file is too large', (tester) async {
      final state = _TestAppState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => Uint8List(1024 * 1024 + 1),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('配对文件过大'), findsOneWidget);
      expect(state.imported, isNull);
    });

    testWidgets('shows an error for missing fields', (tester) async {
      final state = _TestAppState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => utf8.encode('{"ok":true}'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('配对文件缺少必要字段'), findsOneWidget);
      expect(state.imported, isNull);
    });

    testWidgets('shows an error when the picker fails', (tester) async {
      final state = _TestAppState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => throw Exception('no file picker'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('无法打开文件选择器'), findsOneWidget);
      expect(state.imported, isNull);
    });

    testWidgets('shows manual path fallback when picker is cancelled', (tester) async {
      final state = _TestAppState();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PairingSetupView(
              pickFile: () async => null,
            ),
          ),
        ),
      );

      await tester.tap(find.text('选择配对文件'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('输入配对文件路径'), findsOneWidget);
      expect(state.imported, isNull);
    });
  });
}
