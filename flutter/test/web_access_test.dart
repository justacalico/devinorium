import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// ApiService stub for the settings-page loaders plus the web-access route
/// under test.
class _WebAccessApi extends ApiService {
  _WebAccessApi() : super(client: _ThrowingClient());

  bool enabled = false;
  int getCalls = 0;
  List<bool> saved = [];
  Object? saveError;

  @override
  Future<bool> webAccess() async {
    getCalls++;
    return enabled;
  }

  @override
  Future<bool> saveWebAccess(bool v) async {
    if (saveError != null) throw saveError!;
    saved.add(v);
    enabled = v;
    return v;
  }

  // Settings-page loaders.
  @override
  Future<List<McpServerConfig>> mcpServers() async => [];
  @override
  Future<List<GitConnection>> listGitConnections() async => [];
  @override
  Future<List<Machine>> machines() async => [];
  @override
  Future<String?> getCloneRoot() async => null;
  @override
  Future<String?> getWorktreeRoot() async => null;
  @override
  Future<String?> getProjectRoot() async => null;
  @override
  Future<ProviderVersion> providerVersion({String? provider}) =>
      throw ApiException('not found', 404);
  @override
  Future<TailscaleInfo> tailscaleStatus() =>
      throw ApiException('not found', 404);
  @override
  Future<List<User>> listUsers() async => [];
  @override
  Future<FederationNodesResponse> federationNodes() async =>
      FederationNodesResponse(nodes: const []);
}

User _owner() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

User _member() => User(
  id: 2,
  username: 'alice',
  role: 'user',
  totpEnabled: false,
  isOwner: false,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

void main() {
  group('web access api', () {
    test('webAccess gets the flag', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/settings/web-access');
        return _json(200, {'enabled': true});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      expect(await service.webAccess(), isTrue);
    });

    test('saveWebAccess puts the flag', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/api/settings/web-access');
        final body = jsonDecode(req.body);
        expect(body['enabled'], isTrue);
        return _json(200, body);
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      expect(await service.saveWebAccess(true), isTrue);
    });
  });

  group('web access store', () {
    test('loadWebAccess loads the flag for owners', () async {
      final api = _WebAccessApi()..enabled = true;
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      await state.loadWebAccess();
      expect(state.webAccessEnabled, isTrue);
      expect(api.getCalls, 1);
    });

    test('loadWebAccess skips non-owners and clears a stale flag', () async {
      final api = _WebAccessApi()..enabled = true;
      final state = AppState.test(
        api: api,
        user: _member(),
        webAccessEnabled: true,
      );
      addTearDown(state.dispose);

      await state.loadWebAccess();
      expect(api.getCalls, 0);
      expect(state.webAccessEnabled, isFalse);
    });

    test('saveWebAccess stores the server response', () async {
      final api = _WebAccessApi();
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      expect(await state.saveWebAccess(true), isNull);
      expect(api.saved, [true]);
      expect(state.webAccessEnabled, isTrue);
    });

    test('saveWebAccess returns the api error message', () async {
      final api = _WebAccessApi()..saveError = ApiException('forbidden', 403);
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      expect(await state.saveWebAccess(true), 'forbidden');
      expect(state.webAccessEnabled, isFalse);
    });
  });

  group('web access settings section', () {
    // Owner order: account, providers, personalization, git, directories,
    // manage, about, servers, usage, audit, mcp, webAccess.
    const webAccessTopicIndex = 11;

    void bigSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Widget settings(AppState state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const SettingsPage(),
      ),
    );

    testWidgets('shows the toggle and loads the flag', (tester) async {
      bigSurface(tester);
      final api = _WebAccessApi()..enabled = true;
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: webAccessTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('Web access'), findsWidgets); // topic + section
      expect(find.text('Allow agents to use the web'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('web_access_enabled')),
      );
      expect(toggle.value, isTrue);
      expect(api.getCalls, 1);
    });

    testWidgets('tapping the toggle saves the new value', (tester) async {
      bigSurface(tester);
      final api = _WebAccessApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: webAccessTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('web_access_enabled')));
      await tester.pumpAndSettle();

      expect(api.saved, [true]);
      expect(state.webAccessEnabled, isTrue);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('web_access_enabled')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('a save failure keeps the flag and reports the error', (
      tester,
    ) async {
      bigSurface(tester);
      final api = _WebAccessApi()..saveError = ApiException('forbidden', 403);
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: webAccessTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('web_access_enabled')));
      await tester.pumpAndSettle();

      expect(api.saved, isEmpty);
      expect(state.webAccessEnabled, isFalse);
      expect(state.globalError, 'forbidden');
    });

    testWidgets('non-owners see an empty section', (tester) async {
      bigSurface(tester);
      final api = _WebAccessApi();
      final state = AppState.test(api: api, user: _member());
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('web_access_enabled')), findsNothing);
      expect(api.getCalls, 0);
    });
  });
}
