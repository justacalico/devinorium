part of 'package:devinorium_frontend/state/app_state.dart';

mixin CoreStore on AppStateBase {
  // Errors are keyed by subsystem so a background write (or its matching
  // clear) cannot erase an unrelated failure. Unkeyed writers share the
  // 'general' bucket.
  @override
  final Map<String, String> _globalErrors = {};
  @override
  String _lastThreadError = '';
  @override
  String get _globalError => _globalErrors['general'] ?? '';
  @override
  set _globalError(String value) {
    if (value.isEmpty) {
      _globalErrors.remove('general');
    } else {
      _globalErrors['general'] = value;
    }
  }
  @override
  String get globalError => _globalErrors.values.join('\n');
  @override
  void _setKeyedError(String key, String message) {
    _globalErrors[key] = message;
  }
  @override
  void _clearKeyedError(String key) {
    _globalErrors.remove(key);
  }
  @override
  void setGlobalError(String e) {
    _globalError = e;
    notifyListeners();
  }
  @override
  void clearGlobalError() {
    _globalErrors.clear();
    notifyListeners();
  }
}
