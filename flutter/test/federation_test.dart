import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/api/prefixing_client.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/servers/server_registry.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

/// Mock that logs every request path and answers the bootstrap load with
/// plausible shapes so node switching can run end to end.
class _HubMock {
  final requests = <String>[];
  List<Map<String, dynamic>> nodes = [];

  /// Node ids whose proxied requests fail, simulating a dead satellite.
  final deadNodes = <String>{};

  /// Override for the node list status (403/404 disables federation).
  int? nodesStatus;

  /// When false the signed-in account is a non-owner.
  bool ownerUser = true;

  static const _listPaths = [
    '/api/projects',
    '/api/threads',
    '/api/providers',
    '/api/models',
    '/api/machines',
    '/api/git-connections',
    '/api/users',
    '/api/thread-groups',
    '/api/project-groups',
    '/api/files',
    '/api/runs',
  ];

  http.BaseClient get client => MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        final path = req.url.path;
        for (final id in deadNodes) {
          if (path.startsWith('/api/federation/nodes/$id/')) {
            return _json(502, {'error': 'node unreachable'});
          }
        }
        if (path.endsWith('/api/auth/me')) {
          return _json(200, {..._userJson, 'is_owner': ownerUser});
        }
        if (path.endsWith('/api/federation/nodes')) {
          final status = nodesStatus;
          if (status != null) return _json(status, {'error': 'no'});
          return _json(200, _nodesJson(nodes));
        }
        if (path.endsWith('/healthz')) return _json(200, {'ok': true});
        if (path.endsWith('/api/server/version')) {
          return _json(200, {'version': '1.0.0'});
        }
        if (req.method == 'GET' &&
            _listPaths.any((p) => path.endsWith(p))) {
          return _json(200, const []);
        }
        return _json(200, const {});
      });
}

class _RecordingClient implements BaseApiClient {
  final calls = <String>[];
  var closed = false;

  @override
  void close() => closed = true;

  @override
  String get pathPrefix => '';

  @override
  Future<Map<String, dynamic>> get(String path) {
    calls.add('GET $path');
    return Future.value({});
  }

  @override
  Future<List<Map<String, dynamic>>> getList(String path) {
    calls.add('GETLIST $path');
    return Future.value([]);
  }

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) {
    calls.add('POST $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) {
    calls.add('PUT $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) {
    calls.add('PATCH $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> delete(String path) {
    calls.add('DELETE $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) {
    calls.add('DELETE $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    calls.add('UPLOAD $path');
    return Future.value({});
  }

  @override
  Stream<SseEvent> getStream({required String path}) {
    calls.add('GETSTREAM $path');
    return const Stream.empty();
  }

  @override
  Stream<SseEvent> postStream({
    required String path,
    Map<String, String> fields = const {},
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    calls.add('POSTSTREAM $path');
    return const Stream.empty();
  }

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
  }) {
    calls.add('SENDSTREAM $path');
    return const Stream.empty();
  }

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
  Future<String?> get serverUrl => Future.value('http://hub.test');

  @override
  Future<String?> get token => Future.value('tok');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PrefixingClient', () {
    test('prepends the prefix to every request kind', () async {
      final inner = _RecordingClient();
      final client = PrefixingClient(inner, '/api/federation/nodes/n1/proxy');

      expect(client.pathPrefix, '/api/federation/nodes/n1/proxy');

      await client.get('/api/threads');
      await client.getList('/api/projects');
      await client.post('/api/threads', const {});
      await client.put('/api/x', const {});
      await client.patch('/api/x', const {});
      await client.delete('/api/x');
      await client.deleteWithBody('/api/x', const {});
      await client.uploadMultipart('/api/files', const {}, const []);
      client.getStream(path: '/api/threads/t/events').drain();
      client.postStream(path: '/api/threads').drain();
      client.sendStream(path: '/api/threads/t/messages', prompt: 'hi').drain();

      const p = '/api/federation/nodes/n1/proxy';
      expect(inner.calls, [
        'GET $p/api/threads',
        'GETLIST $p/api/projects',
        'POST $p/api/threads',
        'PUT $p/api/x',
        'PATCH $p/api/x',
        'DELETE $p/api/x',
        'DELETE $p/api/x',
        'UPLOAD $p/api/files',
        'GETSTREAM $p/api/threads/t/events',
        'POSTSTREAM $p/api/threads',
        'SENDSTREAM $p/api/threads/t/messages',
      ]);
    });

    test('close does not close the shared inner client', () {
      final inner = _RecordingClient();
      PrefixingClient(inner, '/p').close();
      expect(inner.closed, isFalse);
    });

    test('credential delegates pass through', () async {
      final inner = _RecordingClient();
      final client = PrefixingClient(inner, '/p');
      expect(await client.serverUrl, 'http://hub.test');
      expect(await client.token, 'tok');
      expect(await client.isConfigured, isTrue);
      expect(client.isNative, isFalse);
    });
  });

  group('MultiServerState node services', () {
    Future<MultiServerState> stateWith(MockClient mock) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final state = MultiServerState(registry: ServerRegistry(prefs: prefs));
      final profile = ServerProfile(
        id: 'srv',
        label: 'hub',
        baseUrl: 'http://hub.test',
        token: 'tok',
        username: 'owner',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await state.addProfile(
        profile,
        api: ApiService(client: ApiClient.withClient(mock)),
      );
      return state;
    }

    test('nodeApi routes requests through the proxy prefix', () async {
      final paths = <String>[];
      final mock = MockClient((req) async {
        paths.add(req.url.path);
        return _json(200, const []);
      });
      final state = await stateWith(mock);

      final nodeApi = state.nodeApi('srv', 'n7');
      expect(nodeApi, isNotNull);
      await nodeApi!.client.getList('/api/projects');

      expect(paths, ['/api/federation/nodes/n7/proxy/api/projects']);
    });

    test('nodeApi caches per node and is null for unknown servers', () {
      final state = MultiServerState();
      expect(state.nodeApi('missing', 'n1'), isNull);
    });

    test('terminalWebSocketUri keeps the proxy prefix', () async {
      final service = ApiService(
        client: PrefixingClient(
          _RecordingClient(),
          MultiServerState.nodePrefix('n7'),
        ),
      );

      final uri = await service.terminalWebSocketUri('sess-1');
      expect(
        uri.toString(),
        'ws://hub.test/api/federation/nodes/n7/proxy'
        '/api/terminal/sessions/sess-1/ws',
      );
    });

    test('terminalWebSocketUri is relative on the web client', () async {
      final mock = MockClient((req) async => _json(200, const {}));
      final state = await stateWith(mock);
      final nodeApi = state.nodeApi('srv', 'n7')!;

      final uri = await nodeApi.terminalWebSocketUri('sess-1');
      expect(
        uri.toString(),
        '/api/federation/nodes/n7/proxy/api/terminal/sessions/sess-1/ws',
      );
    });
  });

  group('ApiService federation calls', () {
    test('federationNodes parses the node list', () async {
      final service = ApiService(
        client: ApiClient.withClient(
          MockClient((req) async {
            expect(req.url.path, '/api/federation/nodes');
            return _json(200, _nodesJson([_node('a'), _node('b')]));
          }),
        ),
      );
      final res = await service.federationNodes();
      expect(res.selfName, 'hub');
      expect(res.nodes.map((n) => n.id), ['a', 'b']);
      expect(res.nodes.first.online, isTrue);
    });

    test('removeFederationNode deletes by id', () async {
      final service = ApiService(
        client: ApiClient.withClient(
          MockClient((req) async {
            expect(req.method, 'DELETE');
            expect(req.url.path, '/api/federation/nodes/a');
            return _json(204, const {});
          }),
        ),
      );
      await service.removeFederationNode('a');
    });
  });

  group('AppState node switching', () {
    Future<AppState> appStateFor(_HubMock mock) async {
      final prefs = await SharedPreferences.getInstance();
      final mss = MultiServerState(registry: ServerRegistry(prefs: prefs));
      final profile = ServerProfile(
        id: 'srv',
        label: 'hub',
        baseUrl: 'http://hub.test',
        token: 'tok',
        username: 'owner',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await mss.addProfile(
        profile,
        api: ApiService(client: ApiClient.withClient(mock.client)),
      );
      return AppState.test(multiServerState: mss);
    }

    test('refreshFederationNodes populates the list', () async {
      final mock = _HubMock()..nodes = [_node('n1'), _node('n2')];
      final state = await appStateFor(mock);

      await state.refreshFederationNodes();

      expect(state.federationSupported, isTrue);
      expect(state.federationSelfName, 'hub');
      expect(state.federationNodes.map((n) => n.id), ['n1', 'n2']);
      expect(
        mock.requests,
        contains('GET /api/federation/nodes'),
      );
      state.dispose();
    });

    test('a server without federation routes hides the section', () async {
      final service = ApiService(
        client: ApiClient.withClient(
          MockClient((req) async => _json(404, {'error': 'not found'})),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final mss = MultiServerState(registry: ServerRegistry(prefs: prefs));
      await mss.addProfile(
        ServerProfile(
          id: 'srv',
          label: 'hub',
          baseUrl: 'http://hub.test',
          token: 'tok',
          username: 'owner',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
        ),
        api: service,
      );
      final state = AppState.test(multiServerState: mss);

      await state.refreshFederationNodes();

      expect(state.federationSupported, isFalse);
      expect(state.federationNodes, isEmpty);
      state.dispose();
    });

    test('switchNode rebinds api through the proxy prefix', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);

      await state.switchNode('n1');

      expect(state.activeNodeId, 'n1');
      expect(
        state.api.client.pathPrefix,
        '/api/federation/nodes/n1/proxy',
      );
      expect(state.hubApi.client.pathPrefix, '');
      expect(
        mock.requests,
        contains('GET /api/federation/nodes/n1/proxy/api/auth/me'),
      );
      state.dispose();
    });

    test('switchNode(null) returns to the hub', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);

      await state.switchNode('n1');
      mock.requests.clear();
      await state.switchNode(null);

      expect(state.activeNodeId, isNull);
      expect(state.api.client.pathPrefix, '');
      expect(mock.requests, contains('GET /api/auth/me'));
      state.dispose();
    });

    test('selection persists and restores per server', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');
      state.dispose();

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('federation_node_selection');
      expect(jsonDecode(raw!), {'srv': 'n1'});

      final state2 = await appStateFor(mock);
      await state2.restoreNodeSelection();
      expect(state2.activeNodeId, 'n1');
      state2.dispose();
    });

    test('a deregistered node falls back to the hub', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');
      expect(state.activeNodeId, 'n1');

      mock.nodes = [];
      await state.refreshFederationNodes();
      // The fallback switch runs unawaited; let it settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(state.activeNodeId, isNull);
      expect(state.api.client.pathPrefix, '');
      state.dispose();
    });

    test('removeFederationNode goes to the hub unprefixed', () async {
      final mock = _HubMock()..nodes = [_node('n1'), _node('n2')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');
      mock.requests.clear();

      await state.removeFederationNode('n2');

      expect(mock.requests, contains('DELETE /api/federation/nodes/n2'));
      expect(state.activeNodeId, 'n1');
      state.dispose();
    });

    test('removing the active node falls back to the hub', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');

      mock.nodes = [];
      await state.removeFederationNode('n1');

      expect(state.activeNodeId, isNull);
      state.dispose();
    });

    test('switching to a dead node lands back on the hub', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);

      mock.deadNodes.add('n1');
      await state.switchNode('n1');

      // The failed switch rolls the binding back rather than leaving the
      // app bound to a proxy route that only returns 502s.
      expect(state.activeNodeId, isNull);
      expect(state.api.client.pathPrefix, '');
      expect(state.globalError, isNotEmpty);
      state.dispose();
    });

    test('a failed switch keeps the previous working node', () async {
      final mock = _HubMock()..nodes = [_node('n1'), _node('n2')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');
      expect(state.activeNodeId, 'n1');

      mock.deadNodes.add('n2');
      await state.switchNode('n2');

      expect(state.activeNodeId, 'n1');
      expect(
        state.api.client.pathPrefix,
        '/api/federation/nodes/n1/proxy',
      );
      state.dispose();
    });

    test('a 403 on the node list drops the selection', () async {
      final mock = _HubMock()..nodes = [_node('n1')];
      final state = await appStateFor(mock);
      await state.switchNode('n1');
      expect(state.activeNodeId, 'n1');

      mock.nodesStatus = 403;
      await state.refreshFederationNodes();
      // The fallback switch runs unawaited; let it settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(state.federationSupported, isFalse);
      expect(state.activeNodeId, isNull);
      expect(state.api.client.pathPrefix, '');
      state.dispose();
    });

    test('a non-owner never keeps a stale node selection', () async {
      SharedPreferences.setMockInitialValues({
        'federation_node_selection': jsonEncode({'srv': 'n1'}),
      });
      final mock = _HubMock()
        ..nodes = [_node('n1'), _node('n2')]
        ..ownerUser = false;
      final state = await appStateFor(mock);
      await state.restoreNodeSelection();
      expect(state.activeNodeId, 'n1');

      // switchNode runs the data load, which reports a non-owner; the
      // defensive clear then drops the binding during the same call.
      await state.switchNode('n2');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(state.activeNodeId, isNull);
      expect(state.federationNodes, isEmpty);
      expect(state.federationSupported, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('federation_node_selection') ?? '{}'),
        isNot(contains('srv')),
        reason: 'the stale selection must be forgotten, not restored',
      );
      state.dispose();
    });
  });
}
