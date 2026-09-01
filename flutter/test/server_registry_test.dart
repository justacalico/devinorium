import 'dart:convert';

import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/servers/server_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('ServerRegistry', () {
    Future<SharedPreferences> freshPrefs() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      return prefs;
    }

    test('loadProfiles returns empty when nothing is stored', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final profiles = await registry.loadProfiles();
      expect(profiles, isEmpty);
    });

    test('upsert persists a profile and makes it primary', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final profile = ServerProfile(
        id: 'a',
        label: 'one',
        baseUrl: 'http://one',
        token: 't1',
        username: 'u1',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final updated = await registry.upsert(profile);
      expect(updated, hasLength(1));
      expect(updated.first.isPrimary, isTrue);

      final loaded = await registry.loadProfiles();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'a');
      expect(loaded.first.token, 't1');
    });

    test('adding a second primary demotes the first', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final first = ServerProfile(
        id: 'a',
        label: 'one',
        baseUrl: 'http://one',
        token: 't1',
        username: 'u1',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final second = ServerProfile(
        id: 'b',
        label: 'two',
        baseUrl: 'http://two',
        token: 't2',
        username: 'u2',
        createdAt: DateTime(2024, 1, 2).toUtc(),
        isPrimary: true,
      );
      await registry.upsert(first);
      final profiles = await registry.upsert(second);
      expect(profiles, hasLength(2));
      expect(profiles.firstWhere((p) => p.id == 'a').isPrimary, isFalse);
      expect(profiles.firstWhere((p) => p.id == 'b').isPrimary, isTrue);
    });

    test('remove deletes a profile and returns the remainder', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final first = ServerProfile(
        id: 'a',
        label: 'one',
        baseUrl: 'http://one',
        token: 't1',
        username: 'u1',
        createdAt: DateTime(2024, 1, 1).toUtc(),
      );
      final second = ServerProfile(
        id: 'b',
        label: 'two',
        baseUrl: 'http://two',
        token: 't2',
        username: 'u2',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await registry.upsert(first);
      await registry.upsert(second);

      final remaining = await registry.remove('a');
      expect(remaining, hasLength(1));
      expect(remaining.first.id, 'b');

      final loaded = await registry.loadProfiles();
      expect(loaded, hasLength(1));
    });

    test('primaryProfile returns the primary or the first profile', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final primary = ServerProfile(
        id: 'a',
        label: 'one',
        baseUrl: 'http://one',
        token: 't1',
        username: 'u1',
        createdAt: DateTime(2024, 1, 1).toUtc(),
        isPrimary: true,
      );
      final other = ServerProfile(
        id: 'b',
        label: 'two',
        baseUrl: 'http://two',
        token: 't2',
        username: 'u2',
        createdAt: DateTime(2024, 1, 2).toUtc(),
      );
      await registry.upsert(primary);
      await registry.upsert(other);

      final active = await registry.primaryProfile();
      expect(active?.id, 'a');
    });

    test('skips corrupt entries and keeps valid ones', () async {
      final prefs = await freshPrefs();
      final registry = ServerRegistry(prefs: prefs);
      final valid = ServerProfile(
        id: 'valid',
        label: 'valid',
        baseUrl: 'http://valid',
        token: 't',
        username: 'u',
        createdAt: DateTime(2024, 1, 1).toUtc(),
      );
      await registry.upsert(valid);

      // Corrupt the stored JSON by appending a broken entry.
      final current = prefs.getString('devinorium_servers')!;
      final list = jsonDecode(current) as List<dynamic>;
      list.add({'id': 'broken', 'not_a_valid_field': 123});
      await prefs.setString('devinorium_servers', jsonEncode(list));

      final loaded = await registry.loadProfiles();
      expect(loaded, hasLength(1));
      expect(loaded.first.id, 'valid');
    });

    test('migrates legacy single-server keys once', () async {
      final prefs = await freshPrefs();
      await prefs.setString('devinorium_server_url', 'http://legacy:7878');
      await prefs.setString('devinorium_token', 'legacy-token');
      await prefs.setString('devinorium_username', 'legacy-user');

      final registry = ServerRegistry(prefs: prefs);
      final profiles = await registry.loadProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.first.baseUrl, 'http://legacy:7878');
      expect(profiles.first.token, 'legacy-token');
      expect(profiles.first.username, 'legacy-user');
      expect(profiles.first.isPrimary, isTrue);

      // Legacy keys are removed so the migration only runs once.
      expect(prefs.getString('devinorium_server_url'), isNull);
      expect(prefs.getString('devinorium_token'), isNull);
      expect(prefs.getString('devinorium_username'), isNull);

      // The new registry key is written.
      expect(prefs.getString('devinorium_servers'), isNotNull);

      final secondLoad = await registry.loadProfiles();
      expect(secondLoad, hasLength(1));
      expect(secondLoad.first.baseUrl, 'http://legacy:7878');
    });
  });
}
