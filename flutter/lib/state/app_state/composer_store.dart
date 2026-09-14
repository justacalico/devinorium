part of 'package:devinorium_frontend/state/app_state.dart';

/// SharedPreferences key holding the per-thread composer drafts as a JSON
/// object of `<serverId>:<threadId>` to draft text.
const _composerDraftsKey = 'devinorium_composer_drafts';

mixin ComposerStore on AppStateBase {
  @override
  String _composerText = '';

  /// The thread the scratch [_composerText] was typed for, set alongside it
  /// in [setComposerText]. The store only adopts scratch text it owns, so a
  /// failed openThread cannot smear one thread's input over another's draft.
  @override
  String? _composerTextThreadId;

  @override
  ComposerMode _composerMode = ComposerMode.code;

  /// Unsent composer text per thread, persisted so drafts survive restarts.
  /// Keys are scoped by server so two servers can never collide on a thread
  /// id. The map mirrors what is on disk; writes go through [_saveDraft].
  final Map<String, String> _composerDrafts = {};

  /// Draft keys removed this session before the stored map was loaded, so a
  /// late [_loadComposerDrafts] merge cannot resurrect them.
  final Set<String> _removedDraftKeys = {};

  bool _composerDraftsLoaded = false;

  @override
  String get composerText => _activeStore?.composerText ?? _composerText;
  @override
  ComposerMode get composerMode => _activeStore?.composerMode ?? _composerMode;
  @override
  ComposerMode get defaultComposerMode => _composerMode;

  String _draftKey(String threadId) =>
      '${multiServerState.activeServerId ?? ''}:$threadId';

  /// The persisted draft for [threadId] on the active server, if any.
  String? _draftFor(String threadId) => _composerDrafts[_draftKey(threadId)];

  /// Record [text] as the draft for [threadId] and persist the map. An empty
  /// text deletes the entry so sent or cleared messages do not linger.
  @override
  void _saveDraft(String threadId, String text) =>
      _saveDraftKey(_draftKey(threadId), text);

  void _saveDraftKey(String key, String text) {
    if (text.isEmpty) {
      final had = _composerDrafts.remove(key) != null;
      if (!_composerDraftsLoaded) {
        // Disk may still hold the key until the load merge runs; tombstone
        // it so the merge cannot resurrect a draft this session deleted.
        if (!_removedDraftKeys.add(key) && !had) return;
      } else if (!had) {
        return;
      }
    } else {
      if (_composerDrafts[key] == text) return;
      _composerDrafts[key] = text;
      _removedDraftKeys.remove(key);
    }
    unawaited(_persistComposerDrafts());
  }

  Future<void> _persistComposerDrafts() async {
    // Nothing in memory and nothing deleted: the stored snapshot cannot be
    // stale, so skip the channel round-trip entirely.
    if (!_composerDraftsLoaded &&
        _composerDrafts.isEmpty &&
        _removedDraftKeys.isEmpty) {
      return;
    }
    // Merge the stored map first when a write lands before the bootstrap
    // load; in-session values win over the snapshot.
    if (!_composerDraftsLoaded) await _loadComposerDrafts();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_composerDraftsKey, jsonEncode(_composerDrafts));
    } catch (_) {}
  }

  @override
  Future<void> _loadComposerDrafts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_composerDraftsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString();
            final value = entry.value?.toString() ?? '';
            if (value.isEmpty || _removedDraftKeys.contains(key)) continue;
            _composerDrafts.putIfAbsent(key, () => value);
          }
        }
      }
    } catch (_) {}
    _composerDraftsLoaded = true;
  }

  /// Write the in-memory map out right away; used on dispose so the last
  /// keystrokes are not lost when the app closes.
  void _flushComposerDrafts() {
    unawaited(_persistComposerDrafts());
  }

  @override
  void setComposerText(String t) {
    final store = _activeStore;
    if (store != null) {
      store.setComposerText(t);
    } else {
      _composerText = t;
      // The composer stays enabled while the target thread loads; keep its
      // draft under that thread id so the store adopts it on activation.
      _composerTextThreadId = _activeThreadId;
      if (_composerTextThreadId != null) _saveDraft(_composerTextThreadId!, t);
    }
    notifyListeners();
  }

  @override
  void setComposerMode(ComposerMode m, {bool persist = true}) {
    final store = _activeStore;
    if (store != null) {
      store.composerMode = m;
    } else {
      _composerMode = m;
    }
    notifyListeners();
    if (persist) unawaited(_saveComposerMode(m));
  }
  @override
  Future<void> _saveComposerMode(ComposerMode m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_composer_mode', m.name);
    } catch (_) {}
  }
  @override
  Future<void> _loadComposerMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_composer_mode');
      _composerMode = ComposerModeX.fromString(value);
    } catch (_) {}
    notifyListeners();
  }
}
