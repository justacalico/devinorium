import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'server_profile.dart';

/// Persistence layer for the list of configured Devinorium servers.
///
/// Profiles are stored as a JSON array under `devinorium_servers`. A single
/// profile may be marked `isPrimary`; this is the one the app connects to on
/// cold start. The registry also handles one-time migration from the legacy
/// single-server `SharedPreferences` keys.
class ServerRegistry {
  static const _serversKey = 'devinorium_servers';

  // Legacy keys used by the single-server native client before multi-server.
  static const _legacyUrlKey = 'devinorium_server_url';
  static const _legacyTokenKey = 'devinorium_token';
  static const _legacyUsernameKey = 'devinorium_username';

  final SharedPreferences? _prefs;

  Future<void> _writeTail = Future.value();

  ServerRegistry({this._prefs});

  Future<SharedPreferences> get _preferences async {
    return _prefs ?? await SharedPreferences.getInstance();
  }

  /// Load all saved server profiles. Individual corrupt entries are skipped so
  /// one malformed profile does not wipe the entire list.
  Future<List<ServerProfile>> loadProfiles() async {
    final prefs = await _preferences;
    final raw = prefs.getString(_serversKey);
    if (raw == null || raw.isEmpty) {
      return _migrateFromLegacy(prefs);
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final profiles = <ServerProfile>[];
      for (final e in list) {
        try {
          profiles.add(ServerProfile.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // Skip corrupt entries.
        }
      }
      return profiles;
    } catch (_) {
      return [];
    }
  }

  /// Attempt to load the legacy single-server keys and, if present, save them
  /// as the first primary profile. The legacy keys are removed so the migration
  /// only runs once.
  Future<List<ServerProfile>> _migrateFromLegacy(SharedPreferences prefs) async {
    final url = prefs.getString(_legacyUrlKey);
    final token = prefs.getString(_legacyTokenKey) ?? '';
    final username = prefs.getString(_legacyUsernameKey) ?? '';
    if (url == null || url.isEmpty) {
      return [];
    }
    final profile = ServerProfile(
      id: ServerProfile.generateId(),
      label: _labelFromUrl(url),
      baseUrl: url,
      token: token,
      username: username,
      createdAt: DateTime.now().toUtc(),
      isPrimary: true,
    );
    await saveProfiles([profile]);
    await _clearLegacy(prefs);
    return [profile];
  }

  /// Persist the full list of profiles.
  ///
  /// The bundled local profile is stored without its token: the token is
  /// re-issued on every launch, and keeping it out of SharedPreferences
  /// means it never sits readable on disk between runs.
  Future<void> saveProfiles(List<ServerProfile> profiles) async {
    final prefs = await _preferences;
    final json = profiles
        .map((p) => (p.isLocal ? p.copyWith(token: '') : p).toJson())
        .toList();
    await prefs.setString(_serversKey, jsonEncode(json));
  }

  /// Mutations are read-modify-write against SharedPreferences; serialize
  /// them so a background writer (the local-server refresh) cannot clobber a
  /// user-triggered add/remove/switch in flight.
  Future<T> _serialized<T>(Future<T> Function() op) {
    final prev = _writeTail;
    final completer = Completer<T>();
    _writeTail = prev.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Add or replace a profile. If [profile] is marked primary, all others are
  /// demoted.
  Future<List<ServerProfile>> upsert(ServerProfile profile) {
    return _serialized(() async {
      final profiles = await loadProfiles();
      final index = profiles.indexWhere((p) => p.id == profile.id);
      final updated = index >= 0 ? [...profiles] : [...profiles, profile];
      if (index >= 0) updated[index] = profile;
      if (profile.isPrimary) {
        for (var i = 0; i < updated.length; i++) {
          if (updated[i].id != profile.id) {
            updated[i] = updated[i].copyWith(isPrimary: false);
          }
        }
      }
      await saveProfiles(updated);
      return updated;
    });
  }

  /// Remove a profile by id.
  Future<List<ServerProfile>> remove(String id) {
    return _serialized(() async {
      final profiles = await loadProfiles();
      final updated = profiles.where((p) => p.id != id).toList();
      await saveProfiles(updated);
      return updated;
    });
  }

  /// Promote a profile to primary.
  Future<List<ServerProfile>> setPrimary(String id) {
    return _serialized(() async {
      final profiles = await loadProfiles();
      final updated = profiles
          .map((p) => p.copyWith(isPrimary: p.id == id))
          .toList();
      await saveProfiles(updated);
      return updated;
    });
  }

  /// The currently active (primary) profile, or `null` if none is configured.
  Future<ServerProfile?> primaryProfile() async {
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return null;
    return profiles.firstWhere(
      (p) => p.isPrimary,
      orElse: () => profiles.first,
    );
  }

  Future<void> _clearLegacy(SharedPreferences prefs) async {
    await prefs.remove(_legacyUrlKey);
    await prefs.remove(_legacyTokenKey);
    await prefs.remove(_legacyUsernameKey);
  }

  static String _labelFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty ? uri.host : url;
    } catch (_) {
      return url;
    }
  }
}
