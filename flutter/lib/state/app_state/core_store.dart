part of 'package:devinorium_frontend/state/app_state.dart';

mixin CoreStore on AppStateBase {
  @override
  String _globalError = '';
  @override
  String _lastThreadError = '';
  @override
  String get globalError => _globalError;
  @override
  void setGlobalError(String e) {
    _globalError = e;
    notifyListeners();
  }
  @override
  void clearGlobalError() {
    _globalError = '';
    notifyListeners();
  }
}
