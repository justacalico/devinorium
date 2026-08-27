part of 'package:devinorium_frontend/state/app_state.dart';

mixin ComposerStore on AppStateBase {
  @override
  String _composerText = '';
  @override
  ComposerMode _composerMode = ComposerMode.code;
  @override
  String get composerText => _activeStore?.composerText ?? _composerText;
  @override
  ComposerMode get composerMode => _activeStore?.composerMode ?? _composerMode;
  @override
  void setComposerText(String t) {
    final store = _activeStore;
    if (store != null) {
      store.composerText = t;
    } else {
      _composerText = t;
    }
    notifyListeners();
  }
  @override
  void setComposerMode(ComposerMode m) {
    final store = _activeStore;
    if (store != null) {
      store.composerMode = m;
    } else {
      _composerMode = m;
    }
    notifyListeners();
    unawaited(_saveComposerMode(m));
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
