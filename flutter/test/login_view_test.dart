import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/auth_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeClient implements BaseApiClient {
  _FakeClient({this.isNative = false});

  @override
  final bool isNative;

  String? lastServerUrl;
  String? lastToken;
  String? lastUsername;
  String? _savedServerUrl;

  @override
  Future<bool> get isConfigured async => _savedServerUrl != null && lastToken != null;

  @override
  Future<String?> get serverUrl async => _savedServerUrl;

  @override
  Future<void> setServerUrl(String serverUrl) async {
    lastServerUrl = serverUrl;
    _savedServerUrl = serverUrl;
  }

  @override
  Future<void> setToken(String token) async {
    lastToken = token;
  }

  @override
  Future<void> setUsername(String username) async {
    lastUsername = username;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> clearCredentials() async {}

  @override
  Future<Map<String, dynamic>> get(String path) async {
    if (path == '/api/auth/me') {
      return {
        'id': 1,
        'username': 'owner',
        'role': 'user',
        'totp_enabled': false,
        'is_owner': true,
        'provider_id': 'devin-cli',
        'provider_command': 'devin',
      };
    }
    throw UnimplementedError(path);
  }

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) async {
    if (path == '/api/auth/login') {
      final map = body as Map<String, dynamic>? ?? {};
      if (map['username'] == 'owner' && map['password'] == 'pw') {
        return {
          'ok': true,
          'totp_required': false,
          'username': 'owner',
          'token': isNative ? 'native-token' : '',
        };
      }
      if (map['username'] == 'owner' && map['totp_required'] == true) {
        return {'ok': false, 'totp_required': true, 'username': 'owner', 'token': ''};
      }
      throw Exception('bad password');
    }
    throw UnimplementedError(path);
  }

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getList(String path) =>
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
    List<({String filename, String mime, Uint8List bytes})> attachments = const [],
  }) =>
      Stream.empty();

  @override
  Stream<SseEvent> getStream({required String path}) => Stream.empty();
}

Widget _buildLogin({required _FakeClient client}) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: AppState(api: ApiService(client: client)),
        child: const Scaffold(body: LoginView()),
      ),
    );

void main() {
  testWidgets('LoginView shows server URL field on native', (tester) async {
    final client = _FakeClient(isNative: true);
    await tester.pumpWidget(_buildLogin(client: client));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Server URL'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
  });

  testWidgets('LoginView hides server URL field on web', (tester) async {
    final client = _FakeClient(isNative: false);
    await tester.pumpWidget(_buildLogin(client: client));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Server URL'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
  });

  testWidgets('LoginView submits server URL, username and password on native',
      (tester) async {
    final client = _FakeClient(isNative: true);
    await tester.pumpWidget(_buildLogin(client: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http://'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL'), 'localhost:7878');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(client.lastServerUrl, 'http://localhost:7878');
    expect(client.lastToken, 'native-token');
    expect(client.lastUsername, 'owner');
  });

  testWidgets('LoginView rejects an empty server URL on native', (tester) async {
    final client = _FakeClient(isNative: true);
    await tester.pumpWidget(_buildLogin(client: client));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(client.lastServerUrl, isNull);
  });

  testWidgets('LoginView rejects a host that includes a scheme', (tester) async {
    final client = _FakeClient(isNative: true);
    await tester.pumpWidget(_buildLogin(client: client));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL'), 'http://localhost:7878');
    await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(client.lastServerUrl, isNull);
  });
}
