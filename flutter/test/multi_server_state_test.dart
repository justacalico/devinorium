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
      final profile = ServerProfile(
        id: 'x',
        label: 'x',
        baseUrl: 'http://x',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
      );
      await state.addProfile(profile);

      var calls = 0;
      state.addListener(() => calls++);
      await state.setActiveServer('x');
      expect(calls, greaterThan(0));
    });
  });
}
