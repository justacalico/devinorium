part of 'package:devinorium_frontend/state/app_state.dart';

const _selectedProviderKey = 'devinorium_selected_provider';
const _selectedModelKey = 'devinorium_selected_model';
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
  String _selectedPermission = 'normal';
  @override
  String _selectedProvider = '';
  @override
  String _modelsProvider = '';
  @override
  int _modelsRequestSeq = 0;
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
    unawaited(_saveSelectedModel(m));
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
        await _saveSelectedProvider(_selectedProvider);
        await _saveSelectedModel(_selectedModel);
      } else {
        _selectedModel = '';
        if (store != null) {
          store.selectedModel = '';
        }
        await _saveSelectedProvider(_selectedProvider);
        await _saveSelectedModel('');
      }
    } else if (_selectedProvider == id) {
      // The provider changed but the catalog is missing or stale; keep the
      // provider choice but drop the model so the next relaunch does not pair
      // this provider with an unrelated model.
      _selectedModel = '';
      if (store != null) {
        store.selectedModel = '';
      }
      await _saveSelectedProvider(_selectedProvider);
      await _saveSelectedModel('');
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
    final seq = ++_modelsRequestSeq;
    if (providerId == _modelsProvider && _models.isNotEmpty) {
      _revalidateSelectedModel();
      return;
    }
    try {
      final models = await api.listModels(provider: providerId);
      if (seq != _modelsRequestSeq) return;
      _models = models;
      _modelsProvider = providerId;
      _revalidateSelectedModel();
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

  @override
  Future<void> _loadComposerSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final provider = prefs.getString(_selectedProviderKey) ?? '';
      final model = prefs.getString(_selectedModelKey) ?? '';
      final permission = prefs.getString(_selectedPermissionKey) ?? '';
      if (provider.isNotEmpty) _selectedProvider = provider;
      if (model.isNotEmpty) _selectedModel = model;
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

    String effectiveProvider;
    if (_selectedProvider.isNotEmpty &&
        _providers.any((p) => p.id == _selectedProvider)) {
      effectiveProvider = _selectedProvider;
    } else if (userProvider.isNotEmpty &&
        _providers.any((p) => p.id == userProvider)) {
      effectiveProvider = userProvider;
    } else if (_providers.isNotEmpty) {
      effectiveProvider = _providers.first.id;
    } else {
      effectiveProvider = '';
    }

    if (effectiveProvider.isEmpty) {
      _models = [];
      _modelsProvider = '';
    } else if (effectiveProvider == _modelsProvider && _models.isNotEmpty) {
      _revalidateSelectedModel();
    } else {
      try {
        final models = await api.listModels(provider: effectiveProvider);
        if (seq != _modelsRequestSeq) return;
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
    if (!_knownPermissionModes.contains(_selectedPermission)) {
      _selectedPermission = 'normal';
    }
    notifyListeners();
  }
}
