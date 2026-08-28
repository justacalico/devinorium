part of 'package:devinorium_frontend/state/app_state.dart';

mixin ModelStore on AppStateBase {
  @override
  List<ModelInfo> _models = [];
  @override
  List<ProviderInfo> _providers = [];
  @override
  String _selectedModel = '';
  @override
  String _selectedPermission = 'normal';
  @override
  List<ModelInfo> get models => _models;
  @override
  List<ProviderInfo> get providers => _providers;
  @override
  String get selectedModel => _activeStore?.selectedModel ?? _selectedModel;
  @override
  String get selectedPermission =>
      _activeStore?.selectedPermission ?? _selectedPermission;
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
  Future<void> _loadModelsAndProviders() async {
    await Future.wait([
      (() async {
        try {
          _models = await api.listModels();
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
