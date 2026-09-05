part of 'package:devinorium_frontend/state/app_state.dart';

mixin NavigationStore on AppStateBase {
  @override
  AppView _view = AppView.loading;
  @override
  AppMode _appMode = AppMode.agents;
  @override
  MainPage _page = MainPage.threads;
  @override
  bool _userMenuOpen = false;
  @override
  AppView get view => _view;
  @override
  AppMode get appMode => _appMode;
  @override
  MainPage get page => _page;
  @override
  bool get userMenuOpen => _userMenuOpen;
  @override
  void setView(AppView v) {
    _view = v;
    notifyListeners();
  }
  @override
  void setAppMode(AppMode m) {
    if (_appMode == m) return;
    _appMode = m;
    _page = MainPage.threads;
    _filesPanelOpen = m == AppMode.editor;
    notifyListeners();
  }
  @override
  void setPage(MainPage p) {
    _page = p;
    notifyListeners();
  }
  @override
  void toggleUserMenu() {
    _userMenuOpen = !_userMenuOpen;
    notifyListeners();
  }
  @override
  void setUserMenuOpen(bool v) {
    _userMenuOpen = v;
    notifyListeners();
  }
}
