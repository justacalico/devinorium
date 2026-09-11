import 'package:flutter/foundation.dart';

import '../api/api_service.dart';
import '../api/client_factory.dart';
import 'server_profile.dart';
import 'server_registry.dart';

/// Manages the set of configured Devinorium servers and the currently active
/// one.
///
/// Each profile gets its own [ApiService] so switching between servers does not
/// leak auth headers or cached state. The active server is persisted as the
/// primary profile in [ServerRegistry].
class MultiServerState extends ChangeNotifier {
  /// Stable profile id for the server bundled inside the desktop app.
  static const localProfileId = 'local';

  final ServerRegistry _registry;

  final Map<String, ApiService> _apis = {};
  final Map<String, ServerProfile> _profiles = {};
  String? _activeServerId;

  MultiServerState({ServerRegistry? registry})
      : _registry = registry ?? ServerRegistry();

  /// Load saved profiles and build an [ApiService] for each. On web, an
  /// implicit same-origin profile is created if none exists.
  Future<void> loadFromRegistry() async {
    _apis.clear();
    _profiles.clear();
    _activeServerId = null;

    final loaded = await _registry.loadProfiles();
    final profiles = loaded.isEmpty && kIsWeb ? await _ensureWebProfile() : loaded;

    for (final p in profiles) {
      _profiles[p.id] = p;
      _apis[p.id] = ApiService(client: createApiClient(p));
    }

    if (profiles.isNotEmpty) {
      _activeServerId = profiles.firstWhere(
        (p) => p.isPrimary,
        orElse: () => profiles.first,
      ).id;
    }

    notifyListeners();
  }

  /// The [ApiService] for the currently active server, or `null` if no server
  /// is selected.
  ApiService? get activeApi {
    final id = _activeServerId;
    return id != null ? _apis[id] : null;
  }

  /// The currently active server profile, or `null`.
  ServerProfile? get activeProfile {
    final id = _activeServerId;
    return id != null ? _profiles[id] : null;
  }

  /// The active server id, or `null`.
  String? get activeServerId => _activeServerId;

  /// Look up a profile by id, or `null`.
  ServerProfile? profileById(String id) => _profiles[id];

  /// All configured profiles, active first.
  List<ServerProfile> get profiles {
    final values = _profiles.values.toList();
    values.sort((a, b) {
      if (a.id == _activeServerId) return -1;
      if (b.id == _activeServerId) return 1;
      return a.createdAt.compareTo(b.createdAt);
    });
    return values;
  }

  /// True if at least one server is configured.
  bool get hasAnyServer => _profiles.isNotEmpty;

  /// Persist a new or updated profile and make it the active server. The caller
  /// is responsible for obtaining a valid token before calling this.
  ///
  /// If [api] is provided, it is used as the [ApiService] for this profile
  /// instead of building a new one. This is used by tests that inject a mock
  /// client and by the web client (same-origin cookies).
  Future<void> addProfile(
    ServerProfile profile, {
    bool setActive = true,
    ApiService? api,
  }) async {
    final updated = await _registry.upsert(profile);
    // Apply all returned profiles so primary flags stay in sync.
    for (final p in updated) {
      _profiles[p.id] = p;
    }
    _apis[profile.id] = api ?? ApiService(client: createApiClient(profile));
    if (setActive) {
      _activeServerId = profile.id;
    }
    notifyListeners();
  }

  /// Set the active server by id. Returns `true` if the id existed.
  Future<bool> setActiveServer(String id) async {
    if (!_profiles.containsKey(id)) return false;
    if (_activeServerId == id) return true;
    final updated = await _registry.setPrimary(id);
    for (final p in updated) {
      _profiles[p.id] = p;
    }
    _activeServerId = id;
    notifyListeners();
    return true;
  }

  /// Insert or refresh the bundled-server profile. The endpoint rotates every
  /// launch, so the stored base URL and token are always overwritten. The
  /// profile becomes active only when nothing else is active or it already
  /// was — the user's chosen remote server keeps focus otherwise.
  Future<void> upsertLocalProfile({
    required String baseUrl,
    required String token,
    String username = 'local',
  }) async {
    final existing = _profiles[localProfileId];
    final profile = ServerProfile(
      id: localProfileId,
      label: existing?.label ?? 'local',
      baseUrl: baseUrl,
      token: token,
      username: username,
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
      isPrimary: existing?.isPrimary ?? _activeServerId == null,
      isLocal: true,
    );
    final setActive =
        _activeServerId == null || _activeServerId == localProfileId;
    await addProfile(profile, setActive: setActive);
  }

  /// Remove a server by id. Promotes the most recently created remaining
  /// profile when the active one is removed.
  ///
  /// Bundled local profiles refuse removal: they are managed automatically
  /// and would be recreated on the next launch anyway. [force] bypasses the
  /// guard for internal cleanup (e.g. the bundled binary vanished).
  Future<void> removeServer(String id, {bool force = false}) async {
    final existing = _profiles[id];
    if (!force && existing != null && existing.isLocal) return;
    var remaining = await _registry.remove(id);
    if (_activeServerId == id && remaining.isNotEmpty) {
      remaining = List<ServerProfile>.from(remaining)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final promoted = await _registry.setPrimary(remaining.first.id);
      for (final p in promoted) {
        _profiles[p.id] = p;
      }
    }
    _apis.remove(id);
    _profiles.remove(id);
    if (_activeServerId == id) {
      _activeServerId = remaining.isNotEmpty ? remaining.first.id : null;
    }
    notifyListeners();
  }

  /// Clear the active profile's token, e.g. on logout. The profile stays in the
  /// registry so the user can reconnect.
  Future<void> clearActiveToken() async {
    final id = _activeServerId;
    if (id == null) return;
    final p = _profiles[id];
    if (p == null) return;
    final cleared = p.copyWith(token: '');
    _profiles[id] = cleared;
    _apis[id] = ApiService(client: createApiClient(cleared));
    await _registry.upsert(cleared);
    notifyListeners();
  }

  /// Add a test API service bound to a synthetic profile. Used by
  /// [AppState.test] and widget tests.
  void addTestConnection(ServerProfile profile, ApiService api) {
    _profiles[profile.id] = profile;
    _apis[profile.id] = api;
    _activeServerId = profile.id;
  }

  Future<List<ServerProfile>> _ensureWebProfile() async {
    final profile = ServerProfile(
      id: 'web',
      label: 'web',
      baseUrl: '',
      token: '',
      username: '',
      createdAt: DateTime.now().toUtc(),
      isPrimary: true,
    );
    await _registry.upsert(profile);
    return [profile];
  }
}
