part of 'package:devinorium_frontend/state/app_state.dart';

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
    } else {
      _selectedModel = m;
    }
    notifyListeners();
  }
  @override
  void setSelectedPermission(String p) {
    final store = _activeStore;
    if (store != null) {
      store.selectedPermission = p;
    } else {
      _selectedPermission = p;
    }
    notifyListeners();
  }
  @override
  Future<void> setSelectedProvider(String id) async {
    final store = _activeStore;
    if (store != null) {
      store.selectedProvider = id;
    } else {
      _selectedProvider = id;
    }
    await ensureModelsFor(id);
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
  Future<void> _loadModelsAndProviders() async {
    final provider = _user?.providerId ?? '';
    await Future.wait([
      (() async {
        try {
          _models = await api.listModels(
            provider: provider.isEmpty ? null : provider,
          );
          _modelsProvider = provider;
          if (_models.isNotEmpty && _selectedModel.isEmpty) {
            _selectedModel = _models.first.id;
          }
        } catch (_) {}
      })(),
      (() async {
        try {
          _providers = await api.listProviders();
        } catch (_) {}
      })(),
    ]);
  }
}
