part of 'package:devinorium_frontend/state/app_state.dart';

mixin NavigationStore on AppStateBase {
  @override
  AppView _view = AppView.loading;
  @override
  MainPage _page = MainPage.threads;
  @override
  bool _userMenuOpen = false;
  @override
  AppView get view => _view;
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
