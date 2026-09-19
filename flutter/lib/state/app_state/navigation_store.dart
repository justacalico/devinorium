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
  bool _sidebarOpen = false;
  @override
  AppView get view => _view;
  @override
  AppMode get appMode => _appMode;
  @override
  MainPage get page => _page;
  @override
  bool get userMenuOpen => _userMenuOpen;
  @override
  bool get sidebarOpen => _sidebarOpen;
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
    // The editor's files view only has something to show while a thread is
    // active; without one it would just hide the thread list behind a
    // placeholder, so stay on the thread list instead.
    _filesPanelOpen = m == AppMode.editor && _activeStore != null;
    _gitPanelOpen = false;
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
  @override
  void openSidebar() {
    if (_sidebarOpen) return;
    _sidebarOpen = true;
    notifyListeners();
  }
  @override
  void closeSidebar() {
    if (!_sidebarOpen) return;
    _sidebarOpen = false;
    notifyListeners();
  }
}
