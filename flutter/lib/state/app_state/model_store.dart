part of 'package:devinorium_frontend/state/app_state.dart';

const _selectedProviderKey = 'devinorium_selected_provider';
const _selectedModelKey = 'devinorium_selected_model';
const _selectedReasoningKey = 'devinorium_selected_reasoning';
const _selectedPermissionKey = 'devinorium_selected_permission';
const _knownPermissionModes = {'normal', 'accept-edits', 'smart', 'bypass'};

mixin ModelStore on AppStateBase {
  @override
  List<ModelInfo> _models = [];
  @override
  List<ProviderInfo> _providers = [];
  @override
  ProviderVersion? _providerVersion;
  @override
  String _selectedModel = '';
  @override
  String _selectedReasoning = '';
  @override
  String _selectedPermission = 'normal';
  @override
  String _selectedProvider = '';
  @override
  String _modelsProvider = '';
  @override
  int _modelsRequestSeq = 0;

  /// In-memory model catalog per provider. Tapping through providers in the
  /// model switch does not refetch a provider once it is in here.
  @override
  final Map<String, List<ModelInfo>> _modelsByProvider = {};
  @override
  List<ModelInfo> get models => _models;
  @override
  List<ProviderInfo> get providers => _providers;
  @override
  ProviderVersion? get providerVersion => _providerVersion;
  @override
  Future<void> refreshProviderVersion() async {
    try {
      _providerVersion = await api.providerVersion();
      notifyListeners();
    } catch (_) {
      // Keep the last known value on failure; the row stays unchanged
      // rather than flashing to an unknown state.
    }
  }

  @override
  String get selectedModel => _activeStore?.selectedModel ?? _selectedModel;
  @override
  String get selectedReasoning =>
      _activeStore?.selectedReasoning ?? _selectedReasoning;
  @override
  String get selectedPermission =>
      _activeStore?.selectedPermission ?? _selectedPermission;
  @override
  String get selectedProvider {
    final storeProvider = _activeStore?.selectedProvider;
    if (storeProvider != null && storeProvider.isNotEmpty) {
      return storeProvider;
    }
    if (_selectedProvider.isNotEmpty) return _selectedProvider;
    return _user?.providerId ?? 'devin-cli';
  }

  @override
  void setSelectedModel(String m) {
    final store = _activeStore;
    if (store != null) {
      store.selectedModel = m;
    }
    _selectedModel = m;
    _revalidateSelectedReasoning();
    unawaited(_saveSelectedModel(m));
    unawaited(_saveSelectedReasoning(selectedReasoning));
    notifyListeners();
  }

  @override
  void setSelectedReasoning(String effort) {
    final store = _activeStore;
    if (store != null) {
      store.selectedReasoning = effort;
    }
    _selectedReasoning = effort;
    unawaited(_saveSelectedReasoning(effort));
    notifyListeners();
  }

  @override
  void setSelectedPermission(String p) {
    final store = _activeStore;
    if (store != null) {
      store.selectedPermission = p;
    }
    _selectedPermission = p;
    unawaited(_saveSelectedPermission(p));
    notifyListeners();
  }

  @override
  Future<void> setSelectedProvider(String id) async {
    // A provider known to be missing its CLI cannot be selected. Ids not in
    // the fetched list are allowed so the selection still works before the
    // provider list has loaded.
    for (final p in _providers) {
      if (p.id == id && !p.isAvailable) return;
    }
    final store = _activeStore;
    if (store != null) {
      store.selectedProvider = id;
    }
    _selectedProvider = id;
    await ensureModelsFor(id);
    if (_selectedProvider == id && _modelsProvider == id) {
      if (_models.isNotEmpty) {
        if (!_models.any((m) => m.id == _selectedModel)) {
          _selectedModel = _models.first.id;
          if (store != null) {
            store.selectedModel = _selectedModel;
          }
        }
        _revalidateSelectedReasoning();
        await _saveSelectedProvider(_selectedProvider);
        await _saveSelectedModel(_selectedModel);
        await _saveSelectedReasoning(selectedReasoning);
      } else {
        _selectedModel = '';
        if (store != null) {
          store.selectedModel = '';
        }
        _revalidateSelectedReasoning();
        await _saveSelectedProvider(_selectedProvider);
        await _saveSelectedModel('');
        await _saveSelectedReasoning('');
      }
    } else if (_selectedProvider == id) {
      // The provider changed but the catalog is missing or stale; keep the
      // provider choice but drop the model so the next relaunch does not pair
      // this provider with an unrelated model.
      _selectedModel = '';
      if (store != null) {
        store.selectedModel = '';
      }
      _revalidateSelectedReasoning();
      await _saveSelectedProvider(_selectedProvider);
      await _saveSelectedModel('');
      await _saveSelectedReasoning('');
    }
    notifyListeners();
  }

  /// Load the model catalog for [providerId] when it is not the one currently
  /// held, then drop a selection the provider does not offer. Later calls win:
  /// a stale response for a provider the user already switched away from is
  /// discarded.
  @override
  Future<void> ensureModelsFor(String providerId) async {
    if (providerId.isEmpty) return;

    // A provider whose CLI is missing has no catalog to list.
    for (final p in _providers) {
      if (p.id == providerId && !p.isAvailable) {
        ++_modelsRequestSeq;
        _models = [];
        _modelsProvider = providerId;
        notifyListeners();
        return;
      }
    }

    // Serve from in-memory cache first so switching providers in the picker
    // does not hit the network more than once per provider.
    final cached = _modelsByProvider[providerId];
    if (cached != null) {
      ++_modelsRequestSeq;
      _models = List.of(cached);
      _modelsProvider = providerId;
      _revalidateSelectedModel();
      _revalidateSelectedReasoning();
      notifyListeners();
      return;
    }

    final seq = ++_modelsRequestSeq;
    try {
      final models = await api.listModels(provider: providerId);
      if (seq != _modelsRequestSeq) return;
      _modelsByProvider[providerId] = models;
      _models = models;
      _modelsProvider = providerId;
      _revalidateSelectedModel();
      _revalidateSelectedReasoning();
      notifyListeners();
    } catch (_) {
      // Keep the previous list on failure; the provider may be offline.
    }
  }

  void _revalidateSelectedModel() {
    final selected = selectedModel;
    if (_models.isEmpty || _models.any((m) => m.id == selected)) return;
    final fallback = _models.first.id;
    final store = _activeStore;
    if (store != null) {
      store.selectedModel = fallback;
    } else {
      _selectedModel = fallback;
    }
  }

  /// Keep the selected reasoning effort inside the model's advertised set.
  /// When the model changes or the catalog first loads, a stale value is
  /// replaced by the model's default (or the first supported level).
  void _revalidateSelectedReasoning() {
    ModelInfo? model;
    for (final m in _models) {
      if (m.id == selectedModel) {
        model = m;
        break;
      }
    }
    final supported = model?.supportedReasoningEfforts ?? const <String>[];
    String next;
    if (supported.isEmpty) {
      next = '';
    } else if (supported.contains(selectedReasoning)) {
      next = selectedReasoning;
    } else {
      final fallback = model?.defaultReasoningEffort ?? '';
      next = supported.contains(fallback) ? fallback : supported.first;
    }
    final store = _activeStore;
    if (store != null) {
      store.selectedReasoning = next;
    } else {
      _selectedReasoning = next;
    }
  }

  @override
  Future<void> _loadComposerSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final provider = prefs.getString(_selectedProviderKey) ?? '';
      final model = prefs.getString(_selectedModelKey) ?? '';
      final reasoning = prefs.getString(_selectedReasoningKey) ?? '';
      final permission = prefs.getString(_selectedPermissionKey) ?? '';
      if (provider.isNotEmpty) _selectedProvider = provider;
      if (model.isNotEmpty) _selectedModel = model;
      if (reasoning.isNotEmpty) _selectedReasoning = reasoning;
      if (permission.isNotEmpty && _knownPermissionModes.contains(permission)) {
        _selectedPermission = permission;
      }
    } catch (_) {
      // SharedPreferences may be unavailable in tests; keep the defaults.
    }
  }

  @override
  Future<void> _saveSelectedProvider(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id.isEmpty) {
        await prefs.remove(_selectedProviderKey);
      } else {
        await prefs.setString(_selectedProviderKey, id);
      }
    } catch (_) {}
  }

  @override
  Future<void> _saveSelectedModel(String m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (m.isEmpty) {
        await prefs.remove(_selectedModelKey);
      } else {
        await prefs.setString(_selectedModelKey, m);
      }
    } catch (_) {}
  }

  @override
  Future<void> _saveSelectedReasoning(String effort) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (effort.isEmpty) {
        await prefs.remove(_selectedReasoningKey);
      } else {
        await prefs.setString(_selectedReasoningKey, effort);
      }
    } catch (_) {}
  }

  @override
  Future<void> _saveSelectedPermission(String p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (p.isEmpty) {
        await prefs.remove(_selectedPermissionKey);
      } else {
        await prefs.setString(_selectedPermissionKey, p);
      }
    } catch (_) {}
  }

  @override
  Future<void> _loadModelsAndProviders() async {
    final userProvider = _user?.providerId ?? '';
    final seq = ++_modelsRequestSeq;

    try {
      final providers = await api.listProviders();
      if (seq != _modelsRequestSeq) return;
      _providers = providers;
    } catch (_) {
      if (seq != _modelsRequestSeq) return;
      _providers = [];
    }

    ProviderInfo? findProvider(String id) {
      for (final p in _providers) {
        if (p.id == id) return p;
      }
      return null;
    }

    // Same fallback order as t3code's resolveSelectableProviderInstanceEntry:
    // keep the requested provider only while it is usable, then the account
    // default, then the first available one. When nothing is usable the
    // stored selection is retained so the picker can show it greyed out.
    final selected = findProvider(_selectedProvider);
    final userDefault = findProvider(userProvider);
    ProviderInfo? firstAvailable;
    for (final p in _providers) {
      if (p.isAvailable) {
        firstAvailable = p;
        break;
      }
    }
    final String effectiveProvider;
    if (selected != null && selected.isAvailable) {
      effectiveProvider = selected.id;
    } else if (userDefault != null && userDefault.isAvailable) {
      effectiveProvider = userDefault.id;
    } else if (firstAvailable != null) {
      effectiveProvider = firstAvailable.id;
    } else {
      effectiveProvider = selected?.id ?? (_providers.isNotEmpty ? _providers.first.id : '');
    }

    final effectiveEntry = findProvider(effectiveProvider);
    if (effectiveProvider.isEmpty ||
        (effectiveEntry != null && !effectiveEntry.isAvailable)) {
      // A provider whose CLI is missing has no catalog to list; skip the
      // request rather than making the backend spawn a binary that is not
      // there.
      _models = [];
      _modelsProvider = '';
    } else if (effectiveProvider == _modelsProvider && _models.isNotEmpty) {
      _revalidateSelectedModel();
    } else {
      try {
        final models = await api.listModels(provider: effectiveProvider);
        if (seq != _modelsRequestSeq) return;
        _modelsByProvider[effectiveProvider] = models;
        _models = models;
        _modelsProvider = effectiveProvider;
        _revalidateSelectedModel();
      } catch (_) {
        if (seq != _modelsRequestSeq) return;
        _models = [];
        _modelsProvider = '';
      }
    }

    _selectedProvider = effectiveProvider;
    if (_models.isEmpty) _selectedModel = '';
    _revalidateSelectedReasoning();
    if (!_knownPermissionModes.contains(_selectedPermission)) {
      _selectedPermission = 'normal';
    }
    notifyListeners();
  }
}
