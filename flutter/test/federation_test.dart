import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

const _userJson = {
  'id': 1,
  'username': 'owner',
  'role': 'user',
  'is_owner': true,
  'totp_enabled': false,
  'provider_id': 'devin-cli',
  'provider_command': 'devin',
};

Map<String, dynamic> _nodesJson(List<Map<String, dynamic>> nodes) => {
  'self': {'name': 'hub', 'version': '1.0.0'},
  'nodes': nodes,
};

Map<String, dynamic> _node(String id, {bool online = true}) => {
  'id': id,
  'name': 'node-$id',
  'base_url': 'http://10.0.0.$id:7878',
  'version': '1.0.0',
  'online': online,
  'last_seen_at': DateTime.now().toUtc().toIso8601String(),
};

/// Mock hub answering the federation endpoints and the owner `me` call the
/// node store makes on refresh.
class _HubMock {
  final requests = <(String, String)>[];
  List<Map<String, dynamic>> nodes = [];
  int? nodesStatus;
  bool ownerUser = true;
  Map<String, dynamic>? pairResponse;
  int pairStatus = 201;
  String? pairBody;

  http.BaseClient get client => MockClient((req) async {
    requests.add((req.method, req.url.path));
    if (req.url.path == '/api/federation/nodes/pair' && req is http.Request) {
      pairBody = req.body;
    }
    final path = req.url.path;
    if (path.endsWith('/api/auth/me')) {
      return _json(200, {..._userJson, 'is_owner': ownerUser});
    }
    if (path == '/api/federation/nodes') {
      final status = nodesStatus;
      if (status != null) return _json(status, {'error': 'no'});
      return _json(200, _nodesJson(nodes));
    }
    if (path == '/api/federation/nodes/pair') {
      if (pairStatus != 201) {
        return _json(pairStatus, {'error': 'invalid pairing code'});
      }
      return _json(pairStatus, pairResponse ?? _node('paired'));
    }
    if (path.startsWith('/api/federation/nodes/')) {
      return _json(204, const {});
    }
    if (path.endsWith('/healthz')) return _json(200, {'ok': true});
    if (path.endsWith('/api/server/version')) {
      return _json(200, {'version': '1.0.0'});
    }
    return _json(200, const []);
  });
}

AppState _state(_HubMock mock, {bool owner = true}) {
  mock.ownerUser = owner;
  return AppState.test(
    api: ApiService(client: ApiClient.withClient(mock.client)),
    user: User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      isOwner: owner,
      providerId: 'devin-cli',
      providerCommand: 'devin',
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('node store', () {
    test('refresh populates the paired node list', () async {
      final mock = _HubMock()..nodes = [_node('a'), _node('b', online: false)];
      final state = _state(mock);
      addTearDown(state.dispose);

      await state.refreshFederationNodes();

      expect(state.federationSupported, isTrue);
      expect(state.federationSelfName, 'hub');
      expect(state.federationNodes.map((n) => n.id), ['a', 'b']);
      expect(state.federationNodes.last.online, isFalse);
    });

    test(
      'refresh hides the section when the server has no federation',
      () async {
        final mock = _HubMock()..nodesStatus = 404;
        final state = _state(mock);
        addTearDown(state.dispose);

        await state.refreshFederationNodes();

        expect(state.federationSupported, isFalse);
        expect(state.federationNodes, isEmpty);
      },
    );

    test('refresh skips the request for non-owners', () async {
      final mock = _HubMock();
      final state = _state(mock, owner: false);
      addTearDown(state.dispose);

      await state.refreshFederationNodes();

      expect(state.federationSupported, isFalse);
      expect(
        mock.requests.where((r) => r.$2 == '/api/federation/nodes'),
        isEmpty,
      );
    });

    test('pair posts url and code, then refreshes the list', () async {
      final mock = _HubMock()..pairResponse = _node('new');
      final state = _state(mock);
      addTearDown(state.dispose);

      final error = await state.pairFederationNode(
        url: 'http://10.0.0.9:7878',
        code: 'ABCD-EFGH-IJKL-MNOP',
        name: 'workstation',
      );

      expect(error, isNull);
      expect(
        mock.requests.where((r) => r.$2 == '/api/federation/nodes/pair'),
        hasLength(1),
      );
      // The refresh after pairing picks the node up.
      expect(state.federationNodes.map((n) => n.id), isEmpty);
      mock.nodes = [_node('new')];
      await state.refreshFederationNodes();
      expect(state.federationNodes.single.id, 'new');
    });

    test('pair surfaces the server error message', () async {
      final mock = _HubMock()..pairStatus = 400;
      final state = _state(mock);
      addTearDown(state.dispose);

      final error = await state.pairFederationNode(
        url: 'http://10.0.0.9:7878',
        code: 'WRONG-CODE',
      );

      expect(error, 'invalid pairing code');
    });

    test('remove deletes the node and refreshes', () async {
      final mock = _HubMock()..nodes = [_node('a'), _node('b')];
      final state = _state(mock);
      addTearDown(state.dispose);

      await state.refreshFederationNodes();
      expect(state.federationNodes, hasLength(2));

      mock.nodes = [_node('b')];
      final error = await state.removeFederationNode('a');

      expect(error, isNull);
      expect(
        mock.requests.where(
          (r) => r.$1 == 'DELETE' && r.$2 == '/api/federation/nodes/a',
        ),
        hasLength(1),
      );
      expect(state.federationNodes.single.id, 'b');
    });
  });

  group('node-scoped api calls', () {
    late _RecordedClient client;
    late ApiService api;

    setUp(() {
      client = _RecordedClient();
      api = ApiService(client: client);
    });

    test('listModels forwards node_id', () async {
      await api.listModels(provider: 'devin-cli', nodeId: 'n1');
      expect(client.calls.single, contains('/api/models'));
      expect(client.calls.single, contains('node_id=n1'));
      expect(client.calls.single, contains('provider=devin-cli'));
    });

    test('createProject forwards node_id', () async {
      await api.createProject(name: 'p', path: '/x', nodeId: 'n1');
      final call = client.calls.single;
      expect(call, contains('/api/projects'));
      expect(client.bodies.single['node_id'], 'n1');
    });

    test('createNewProject forwards node_id', () async {
      await api.createNewProject(name: 'p', nodeId: 'n1');
      expect(client.bodies.single['node_id'], 'n1');
    });

    test('cloneRepo forwards node_id', () async {
      await api.cloneRepo('https://x/y.git', nodeId: 'n1');
      expect(client.bodies.single['node_id'], 'n1');
    });

    test('listFiles forwards node_id', () async {
      await api.listFiles(path: '/src', nodeId: 'n1');
      expect(client.calls.single, contains('node_id=n1'));
    });

    test('pairFederationNode posts the pair payload', () async {
      await api.pairFederationNode(url: 'http://n:7878', code: 'C', name: 'x');
      expect(client.bodies.single, {
        'url': 'http://n:7878',
        'code': 'C',
        'name': 'x',
      });
    });
  });

  group('nodes settings card', () {
    Future<AppState> pumpSection(
      WidgetTester tester,
      _HubMock mock, {
      bool owner = true,
    }) async {
      final state = _state(mock, owner: owner);
      state.setSettingsTopicIndex(7); // Servers
      addTearDown(state.dispose);
      await state.refreshFederationNodes();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: state),
              ChangeNotifierProvider<ThemeProvider>(
                create: (_) => ThemeProvider()..loadInitial(),
              ),
            ],
            child: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('lists nodes and offers pairing for owners', (tester) async {
      final mock = _HubMock()..nodes = [_node('a'), _node('b', online: false)];
      await pumpSection(tester, mock);

      await tester.ensureVisible(
        find.byKey(const Key('node_pair_button')).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('node-a'), findsOneWidget);
      expect(find.text('node-b'), findsOneWidget);
      expect(find.text('online'), findsWidgets);
      expect(find.text('offline'), findsWidgets);
      expect(find.text('Pair a machine'), findsWidgets);
    });

    testWidgets('pair dialog calls the pair endpoint', (tester) async {
      final mock = _HubMock()..pairResponse = _node('paired');
      await pumpSection(tester, mock);

      await tester.ensureVisible(
        find.byKey(const Key('node_pair_button')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('node_pair_button')).first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('pair_url')),
        'http://10.0.0.9:7878',
      );
      await tester.enterText(
        find.byKey(const Key('pair_code')),
        'ABCD-EFGH-IJKL-MNOP',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('pair_submit')));
      await tester.pumpAndSettle();

      expect(
        mock.requests.where((r) => r.$2 == '/api/federation/nodes/pair'),
        hasLength(1),
      );
    });

    testWidgets('pair dialog normalizes a bare host:port', (tester) async {
      final mock = _HubMock()..pairResponse = _node('paired');
      await pumpSection(tester, mock);

      await tester.ensureVisible(
        find.byKey(const Key('node_pair_button')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('node_pair_button')).first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('pair_url')),
        '192.168.1.20:7878',
      );
      await tester.enterText(
        find.byKey(const Key('pair_code')),
        'ABCD-EFGH-IJKL-MNOP',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('pair_submit')));
      await tester.pumpAndSettle();

      expect(mock.pairBody, contains('http://192.168.1.20:7878'));
    });

    testWidgets('pair dialog shows the server error', (tester) async {
      final mock = _HubMock()..pairStatus = 400;
      await pumpSection(tester, mock);

      await tester.ensureVisible(
        find.byKey(const Key('node_pair_button')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('node_pair_button')).first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('pair_url')),
        'http://10.0.0.9:7878',
      );
      await tester.enterText(find.byKey(const Key('pair_code')), 'WRONG');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pair_submit')));
      await tester.pumpAndSettle();

      expect(find.text('invalid pairing code'), findsOneWidget);
    });

    testWidgets('hidden for non-owners', (tester) async {
      final mock = _HubMock();
      await pumpSection(tester, mock, owner: false);

      expect(find.text('Pair a machine'), findsNothing);
      expect(find.byKey(const Key('node_pair_button')), findsNothing);
    });
  });
}

/// Records request bodies for the api-level assertions.
class _RecordedClient implements BaseApiClient {
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];

  @override
  void close() {}

  @override
  String get pathPrefix => '';

  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  Future<void> setServerUrl(String serverUrl) => Future.value();

  @override
  Future<void> setToken(String token) => Future.value();

  @override
  Future<void> setUsername(String username) => Future.value();

  @override
  Future<void> clearCredentials() => Future.value();

  @override
  Future<void> init() => Future.value();

  @override
  bool get isNative => false;

  @override
  Future<String?> get serverUrl => Future.value('http://test');

  @override
  Future<String?> get token => Future.value('token');

  Map<String, dynamic> _record(String path, [Object? body]) {
    calls.add(path);
    if (body is Map<String, dynamic>) bodies.add(body);
    if (path.contains('/api/models')) return {'list': []};
    if (path.contains('/api/projects')) {
      return {
        'id': 1,
        'name': 'p',
        'path': '/x',
        'created_at': '',
        'updated_at': '',
      };
    }
    if (path.contains('/api/clones')) return {'path': '/c'};
    if (path.contains('/api/federation/nodes/pair')) {
      return _node('paired');
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> get(String path) async => _record(path);

  @override
  Future<List<Map<String, dynamic>>> getList(String path) async {
    calls.add(path);
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) async =>
      _record(path, body);

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) async =>
      _record(path, body);

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) async =>
      _record(path, body);

  @override
  Future<Map<String, dynamic>> delete(String path) async => _record(path);

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) async =>
      _record(path, body);

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) async => _record(path);

  @override
  Stream<SseEvent> getStream({required String path}) => const Stream.empty();

  @override
  Stream<SseEvent> postStream({
    required String path,
    Map<String, String> fields = const {},
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => const Stream.empty();

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
    List<int> machineIds = const [],
  }) => const Stream.empty();
}
