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
  bool _sidebarCompact = false;
  @override
  bool _sidebarCompactAuto = false;
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

  /// Effective compact state: the user's persisted preference or a
  /// window-width auto-collapse. The editor and open side panels have no
  /// rail rendering, so they suppress compact mode until they close; a
  /// pending auto-collapse then applies on its own. Only the wide layout
  /// reads this; the narrow overlay sidebar ignores it entirely.
  @override
  bool get sidebarCompact =>
      (_sidebarCompact || _sidebarCompactAuto) &&
      _appMode != AppMode.editor &&
      !_filesPanelOpen &&
      !_gitPanelOpen;
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
    _gitPanelOpen = false;
    notifyListeners();
  }

  @override
  void setSidebarCompact(bool compact) {
    // The editor has no usable rail; refuse instead of hiding the tree.
    if (compact && _appMode == AppMode.editor) return;
    // Panels have no compact rendering; collapsing hides them, so close
    // them instead of leaving dead state behind the rail. This can be the
    // only effective change when the pref is already true but suppressed.
    final panelsClosed = compact && (_filesPanelOpen || _gitPanelOpen);
    final stateUnchanged =
        _sidebarCompact == compact && (compact || !_sidebarCompactAuto);
    if (!panelsClosed && stateUnchanged) return;
    if (panelsClosed) {
      _filesPanelOpen = false;
      _gitPanelOpen = false;
    }
    _sidebarCompact = compact;
    // An explicit expand always wins over the window-width auto-collapse.
    if (!compact) _sidebarCompactAuto = false;
    notifyListeners();
    unawaited(_saveSidebarCompact());
  }

  @override
  void toggleSidebarCompact() {
    setSidebarCompact(!sidebarCompact);
  }

  @override
  void expandSidebar() {
    if (!_sidebarCompact && !_sidebarCompactAuto) return;
    _sidebarCompact = false;
    _sidebarCompactAuto = false;
    notifyListeners();
  }

  @override
  void setSidebarCompactAuto(bool compact) {
    if (_sidebarCompactAuto == compact) return;
    // Panels and the editor suppress the effective state, so a pending
    // auto-collapse can be recorded even while it can't apply yet.
    _sidebarCompactAuto = compact;
    notifyListeners();
  }

  @override
  Future<void> _loadSidebarCompact() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _sidebarCompact = prefs.getBool('devinorium_sidebar_compact') ?? false;
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> _saveSidebarCompact() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('devinorium_sidebar_compact', _sidebarCompact);
    } catch (_) {}
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
