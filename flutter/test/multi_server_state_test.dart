import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/servers/server_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MultiServerState', () {
    Future<ServerRegistry> freshRegistry() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      return ServerRegistry(prefs: prefs);
    }

    test('loadFromRegistry restores profiles and active service', () async {
      final registry = await freshRegistry();
      final profile = ServerProfile(
        id: 'a',
        label: 'home',
        baseUrl: 'http://localhost:7878',
        token: 'tok',
        username: 'owner',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await registry.upsert(profile);

      final state = MultiServerState(registry: registry);
      await state.loadFromRegistry();

      expect(state.hasAnyServer, isTrue);
      expect(state.activeServerId, 'a');
      expect(state.activeApi, isNotNull);
      expect(state.activeProfile?.baseUrl, 'http://localhost:7878');
    });

    test('addProfile stores profile and uses provided api', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      final mockClient = ApiClient.withClient(
        MockClient((req) async => _json(200, {'ok': true, 'totp_required': false, 'username': 'owner'})),
      );
      final service = ApiService(client: mockClient);

      final profile = ServerProfile(
        id: 'b',
        label: 'work',
        baseUrl: 'http://work:7878',
        token: 'work-token',
        username: 'owner',
        createdAt: DateTime(2024, 1, 2).toUtc(),
        isPrimary: true,
      );
      await state.addProfile(profile, api: service);

      expect(state.activeServerId, 'b');
      expect(state.activeApi, same(service));
      expect(state.profiles, hasLength(1));
    });

    test('setActiveServer switches active api', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      final alpha = ServerProfile(
        id: 'alpha',
        label: 'alpha',
        baseUrl: 'http://alpha',
        token: 't1',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final beta = ServerProfile(
        id: 'beta',
        label: 'beta',
        baseUrl: 'http://beta',
        token: 't2',
        username: 'u',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await state.addProfile(alpha);
      await state.addProfile(beta, setActive: false);

      expect(state.activeServerId, 'alpha');
      await state.setActiveServer('beta');
      expect(state.activeServerId, 'beta');
      expect(state.activeProfile?.isPrimary, isTrue);
      // alpha should have been demoted in the registry.
      final loaded = await registry.loadProfiles();
      expect(loaded.firstWhere((p) => p.id == 'alpha').isPrimary, isFalse);
      expect(loaded.firstWhere((p) => p.id == 'beta').isPrimary, isTrue);
    });

    test('removeServer drops profile and api', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final profile = ServerProfile(
        id: 'x',
        label: 'x',
        baseUrl: 'http://x',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await state.addProfile(profile);

      await state.removeServer('x');
      expect(state.hasAnyServer, isFalse);
      expect(state.activeApi, isNull);
    });

    test('removeServer promotes the remaining server to primary', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final alpha = ServerProfile(
        id: 'alpha',
        label: 'alpha',
        baseUrl: 'http://alpha',
        token: 't1',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final beta = ServerProfile(
        id: 'beta',
        label: 'beta',
        baseUrl: 'http://beta',
        token: 't2',
        username: 'u',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await state.addProfile(alpha);
      await state.addProfile(beta, setActive: false);

      await state.removeServer('alpha');
      expect(state.activeServerId, 'beta');
      expect(state.activeProfile?.isPrimary, isTrue);
      final loaded = await registry.loadProfiles();
      expect(loaded.firstWhere((p) => p.id == 'beta').isPrimary, isTrue);
    });

    test('clearActiveToken empties the token for the active profile', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final profile = ServerProfile(
        id: 'x',
        label: 'x',
        baseUrl: 'http://x',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await state.addProfile(profile);
      await state.clearActiveToken();

      expect(state.activeProfile?.token, '');
      final loaded = await registry.loadProfiles();
      expect(loaded.first.token, '');
    });

    test('notifies listeners on active server change', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final first = ServerProfile(
        id: 'x',
        label: 'x',
        baseUrl: 'http://x',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
      );
      final second = ServerProfile(
        id: 'y',
        label: 'y',
        baseUrl: 'http://y',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await state.addProfile(first);
      await state.addProfile(second, setActive: false);

      var calls = 0;
      state.addListener(() => calls++);
      await state.setActiveServer('y');
      expect(calls, greaterThan(0));
      expect(state.activeServerId, 'y');
    });

    test('setActiveServer returns true for a known id and false otherwise', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final profile = ServerProfile(
        id: 'x',
        label: 'x',
        baseUrl: 'http://x',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
      );
      await state.addProfile(profile);

      expect(await state.setActiveServer('x'), isTrue);
      expect(await state.setActiveServer('missing'), isFalse);
    });

    test('removeServer promotes the most recently created remaining profile', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final older = ServerProfile(
        id: 'older',
        label: 'older',
        baseUrl: 'http://older',
        token: 't1',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final newer = ServerProfile(
        id: 'newer',
        label: 'newer',
        baseUrl: 'http://newer',
        token: 't2',
        username: 'u',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await state.addProfile(older);
      await state.addProfile(newer, setActive: false);

      await state.removeServer('older');
      expect(state.activeServerId, 'newer');
      expect(state.activeProfile?.isPrimary, isTrue);
    });

    test('upsertLocalProfile activates the local profile when nothing else exists', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'local-token',
      );

      final profile = state.profileById(MultiServerState.localProfileId);
      expect(profile, isNotNull);
      expect(profile!.isLocal, isTrue);
      expect(profile.isPrimary, isTrue);
      expect(state.activeServerId, MultiServerState.localProfileId);
      expect(state.activeApi, isNotNull);
    });

    test('upsertLocalProfile does not steal focus from a remote server', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      final remote = ServerProfile(
        id: 'remote',
        label: 'remote',
        baseUrl: 'http://remote:7878',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      await state.addProfile(remote);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40002',
        token: 'local-token',
      );

      expect(state.activeServerId, 'remote');
      final local = state.profileById(MultiServerState.localProfileId)!;
      expect(local.isLocal, isTrue);
      expect(local.isPrimary, isFalse);
    });

    test('upsertLocalProfile reuses the api when the endpoint is unchanged',
        () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'same-token',
      );
      final first = state.activeApi;
      expect(first, isNotNull);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'same-token',
      );
      expect(
        identical(state.activeApi, first),
        isTrue,
        reason: 'an unchanged endpoint must not churn the api instance',
      );

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40009',
        token: 'new-token',
      );
      expect(
        identical(state.activeApi, first),
        isFalse,
        reason: 'a rotated endpoint gets a fresh api',
      );
    });

    test('upsertLocalProfile refreshes credentials and keeps primary state', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'old-token',
      );
      final createdAt =
          state.profileById(MultiServerState.localProfileId)!.createdAt;

      // Second launch rotates the endpoint but keeps the profile active.
      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40009',
        token: 'new-token',
      );

      final profile = state.profileById(MultiServerState.localProfileId)!;
      expect(profile.baseUrl, 'http://127.0.0.1:40009');
      expect(profile.token, 'new-token');
      expect(profile.createdAt, createdAt);
      expect(profile.isPrimary, isTrue);
      expect(state.activeServerId, MultiServerState.localProfileId);
      expect(state.profiles, hasLength(1));
    });

    test('upsertLocalProfile persists the profile without its token', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);

      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'secret-tok',
      );

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('devinorium_servers')!;
      expect(raw, contains('"is_local":true'));
      expect(raw, isNot(contains('secret-tok')));

      // The in-memory profile still carries the live token.
      expect(
        state.profileById(MultiServerState.localProfileId)!.token,
        'secret-tok',
      );
    });

    test('clearActiveToken leaves the local profile untouched', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 'secret-tok',
      );

      await state.clearActiveToken();

      expect(
        state.profileById(MultiServerState.localProfileId)!.token,
        'secret-tok',
      );
    });

    test('removeServer refuses the bundled local profile unless forced', () async {
      final registry = await freshRegistry();
      final state = MultiServerState(registry: registry);
      await state.upsertLocalProfile(
        baseUrl: 'http://127.0.0.1:40001',
        token: 't',
      );

      await state.removeServer(MultiServerState.localProfileId);
      expect(
        state.profileById(MultiServerState.localProfileId),
        isNotNull,
      );

      await state.removeServer(MultiServerState.localProfileId, force: true);
      expect(state.profileById(MultiServerState.localProfileId), isNull);
      expect(state.hasAnyServer, isFalse);
    });
  });
}
