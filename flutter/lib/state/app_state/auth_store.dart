part of 'package:devinorium_frontend/state/app_state.dart';

mixin AuthStore on AppStateBase {
  @override
  User? _user;
  @override
  List<User> _users = [];
  @override
  List<Device> _devices = [];
  @override
  String _loginError = '';
  @override
  bool _showTotpField = false;
  @override
  String _totpSecret = '';
  @override
  User? get user => _user;
  @override
  List<User> get users => _users;
  @override
  List<Device> get devices => _devices;
  @override
  bool get isOwner => _user?.isOwner ?? false;
  @override
  String get loginError => _loginError;
  @override
  bool get showTotpField => _showTotpField;
  @override
  String get totpSecret => _totpSecret;
  @override
  void setLoginError(String e) {
    _loginError = e;
    notifyListeners();
  }
  @override
  void setShowTotpField(bool v) {
    _showTotpField = v;
    notifyListeners();
  }
  @override
  Future<void> bootstrap() async {
    await _loadThemeMode();
    await _loadLanguage();
    await _loadComposerMode();
    await _loadNotificationPrefs();
    await _loadPlanOverlayState();
    setAppL10n(_locale);
    try {
      final configured = await api.client.isConfigured;
      if (!configured) {
        _view = AppView.login;
        notifyListeners();
        return;
      }
      _user = await api.me();
      _view = AppView.app;
      await Future.wait([_loadModelsAndProviders(), loadProjects()]);
      if (_projects.isNotEmpty) {
        await selectProject(_projects.first.id);
      } else {
        await selectAllProjects();
      }
      startHealthChecks();
      startGitRefresh();
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        await api.client.clearCredentials();
      }
      _view = AppView.login;
      notifyListeners();
    }
  }
  @override
  Future<void> doLogin({
    required String serverUrl,
    required String username,
    required String password,
    String? totp,
  }) async {
    _loginError = '';
    notifyListeners();
    try {
      await api.client.setServerUrl(serverUrl.trim());
      final res = await api.login(
        username: username,
        password: password,
        totp: totp,
      );
      if (res.totpRequired) {
        _view = AppView.login;
        _showTotpField = true;
        _loginError = appL10n.totpPrompt;
        notifyListeners();
        return;
      }
      if (res.token.isNotEmpty) {
        await api.client.setToken(res.token);
        await api.client.setUsername(res.username);
      }
      _user = await api.me();
      _view = AppView.app;
      _showTotpField = false;
      _loginError = '';
      await _loadPlanOverlayState();
      await Future.wait([_loadModelsAndProviders(), loadProjects()]);
      if (_projects.isNotEmpty) {
        await selectProject(_projects.first.id);
      } else {
        await selectAllProjects();
      }
      startHealthChecks();
      startGitRefresh();
    } catch (e) {
      _view = AppView.login;
      _loginError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> loadUsers() async {
    try {
      _users = await api.listUsers();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }
  @override
  Future<void> loadDevices() async {
    try {
      _devices = await api.listDevices();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }
  @override
  Future<void> loadSettingsData() async {
    final futures = <Future<void>>[
      loadDevices(),
      loadGitConnections(),
      loadCloneRoot(),
    ];
    if (isOwner) {
      futures.add(loadUsers());
    }
    await Future.wait(futures);
  }
  @override
  Future<void> revokeDevice(String token) async {
    try {
      await api.revokeDevice(token);
      _globalError = '';
      await loadDevices();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> createUser({
    required String username,
    required String password,
  }) async {
    try {
      await api.createUser(username: username, password: password);
      _globalError = '';
      await loadUsers();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> setUserDisabled(int id, bool disabled) async {
    try {
      await api.setUserDisabled(id, disabled);
      _globalError = '';
      await loadUsers();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> logout() async {
    stopHealthChecks();
    stopGitRefresh();
    for (final store in _threadStores.values) {
      store.dispose();
    }
    _threadStores.clear();
    _activeStore = null;
    _activeThreadId = null;
    try {
      await api.logout();
    } catch (_) {}
    try {
      await api.client.clearCredentials();
    } catch (_) {}
    _user = null;
    _users = [];
    _settingsTopicIndex = 0;
    _view = AppView.login;
    _page = MainPage.threads;
    _userMenuOpen = false;
    _projects = [];
    _projectsOffset = 0;
    _projectsHasMore = true;
    _threads = [];
    _userThreadsOffset = 0;
    _userThreadsHasMore = true;
    _projectThreadOffsets.clear();
    _projectThreadsHasMore.clear();
    _loadingMoreProjectThreads.clear();
    _filesEntries = [];
    _filesOffset = 0;
    _filesHasMore = true;
    _activeProjectId = null;
    _showTotpField = false;
    _loginError = '';
    _composerText = '';
    _composerMode = ComposerMode.code;
    _attachments.clear();
    _selectedModel = '';
    _selectedPermission = 'normal';
    _runningThreadIds.clear();
    _connectionStatus = ConnectionStatus.checking;
    notifyListeners();
  }
  @override
  Future<void> saveProvider({
    String? providerId,
    String? providerCommand,
  }) async {
    final user = _user;
    if (user == null) return;
    try {
      _user = await api.updateMe(
        providerId: providerId ?? user.providerId,
        providerCommand: providerCommand ?? user.providerCommand,
      );
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }
  @override
  Future<void> testProvider({
    required String providerId,
    required String command,
  }) async {
    try {
      await api.testProvider(providerId: providerId, command: command);
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      rethrow;
    }
  }
  @override
  Future<void> openTotpSetup() async {
    try {
      final res = await api.totpSetup();
      _totpSecret = res.secret;
      _dialog = DialogKind.totpSetup;
      _userMenuOpen = false;
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> verifyTotp(String code) async {
    try {
      await api.totpVerify(code);
      _dialog = DialogKind.none;
      _user = await api.me();
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> disableTotp() async {
    try {
      await api.totpDisable();
      _user = await api.me();
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
}
