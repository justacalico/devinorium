part of 'package:devinorium_frontend/state/app_state.dart';

mixin AuthStore on AppStateBase {
  bool _switchingServer = false;

  @override
  User? _user;
  @override
  List<User> _users = [];
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
    await _loadLanguage();
    await _loadComposerMode();
    await _loadNotificationPrefs();
    await _loadPlanOverlayState();
    setAppL10n(_locale);
    try {
      if (!multiServerState.hasAnyServer) {
        await multiServerState.loadFromRegistry();
      }
      final active = multiServerState.activeApi;
      if (active == null || !(await active.client.isConfigured)) {
        _view = AppView.login;
        notifyListeners();
        return;
      }
      await _loadUserAndData();
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        await multiServerState.clearActiveToken();
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
      final profile = await _performServerLogin(
        serverUrl: serverUrl,
        username: username,
        password: password,
        totp: totp,
      );
      if (profile == null) {
        _view = AppView.login;
        _showTotpField = true;
        _loginError = appL10n.totpPrompt;
        notifyListeners();
        return;
      }
      await multiServerState.addProfile(
        profile.copyWith(isPrimary: true),
        setActive: true,
        api: _apiForNewProfile(),
      );
      await _loadUserAndData();
    } catch (e) {
      _view = AppView.login;
      _loginError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<String?> addServer({
    required String serverUrl,
    required String username,
    required String password,
    String? totp,
  }) async {
    _globalError = '';
    notifyListeners();
    try {
      final profile = await _performServerLogin(
        serverUrl: serverUrl,
        username: username,
        password: password,
        totp: totp,
      );
      if (profile == null) {
        _globalError = appL10n.totpPrompt;
        notifyListeners();
        return _globalError;
      }
      await multiServerState.addProfile(
        profile.copyWith(isPrimary: false),
        setActive: false,
        api: _apiForNewProfile(),
      );
      _globalError = '';
      notifyListeners();
      return null;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return _globalError;
    }
  }

  Future<ServerProfile?> _performServerLogin({
    required String serverUrl,
    required String username,
    required String password,
    String? totp,
  }) async {
    final trimmedUrl = serverUrl.trim();
    final loginApi = _loginApiFor(trimmedUrl);
    final res = await loginApi.login(
      username: username,
      password: password,
      totp: totp,
    );
    if (res.totpRequired) return null;
    await _configureLoginClient(
      trimmedUrl,
      res.token,
      res.username.isNotEmpty ? res.username : username.trim(),
    );
    return ServerProfile(
      id: ServerProfile.generateId(),
      label: _serverLabel(trimmedUrl),
      baseUrl: trimmedUrl,
      token: res.token,
      username: res.username.isNotEmpty ? res.username : username.trim(),
      createdAt: DateTime.now().toUtc(),
      isPrimary: true,
    );
  }

  ApiService _loginApiFor(String serverUrl) {
    if (_isRealNativeClient(api.client)) {
      final tempProfile = ServerProfile(
        id: ServerProfile.generateId(),
        label: _serverLabel(serverUrl),
        baseUrl: serverUrl,
        token: '',
        username: '',
        createdAt: DateTime.now().toUtc(),
        isPrimary: true,
      );
      return ApiService(client: createApiClient(tempProfile));
    }
    return api;
  }

  Future<void> _configureLoginClient(
    String serverUrl,
    String token,
    String username,
  ) async {
    final client = api.client;
    if (_isRealNativeClient(client)) {
      // Real native clients get a fresh service per profile; no need to mutate
      // the transient unconfigured client.
      return;
    }
    await client.setServerUrl(serverUrl);
    await client.setToken(token);
    await client.setUsername(username);
  }

  bool _isRealNativeClient(BaseApiClient client) {
    if (client is NativeApiClient) return true;
    if (client is PreloaderClient) return client.inner is NativeApiClient;
    return false;
  }

  ApiService? _apiForNewProfile() {
    if (_isRealNativeClient(api.client)) return null;
    if (kIsWeb) return ApiService(client: createApiClient());
    return ApiService(client: api.client);
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
  Future<void> loadSettingsData() async {
    final futures = <Future<void>>[loadGitConnections(), loadCloneRoot()];
    if (isOwner) {
      futures.add(loadUsers());
    }
    await Future.wait(futures);
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
    await multiServerState.clearActiveToken();
    _resetServerState();
    _settingsTopicIndex = 0;
    _userMenuOpen = false;
    _view = AppView.login;
    notifyListeners();
  }

  @override
  Future<void> switchServer(String serverId) async {
    if (_switchingServer) return;
    _switchingServer = true;
    stopHealthChecks();
    stopGitRefresh();
    _resetServerState();
    try {
      final ok = await multiServerState.setActiveServer(serverId);
      if (!ok) throw StateError('server not found');
      await _loadUserAndData();
    } catch (e) {
      _view = AppView.login;
      _loginError = '$e';
      notifyListeners();
    } finally {
      _switchingServer = false;
    }
  }

  @override
  Future<void> removeServer(String serverId) async {
    if (_switchingServer) return;
    _switchingServer = true;
    try {
      final wasActive = multiServerState.activeServerId == serverId;
      if (wasActive) {
        stopHealthChecks();
        stopGitRefresh();
        _resetServerState();
      }
      await multiServerState.removeServer(serverId);
      if (wasActive) {
        if (multiServerState.activeApi != null) {
          await _loadUserAndData();
        } else {
          _view = AppView.login;
          notifyListeners();
        }
      }
    } catch (e) {
      _view = AppView.login;
      _loginError = '$e';
      notifyListeners();
    } finally {
      _switchingServer = false;
    }
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

  Future<void> _loadUserAndData() async {
    _showTotpField = false;
    _loginError = '';
    _user = await api.me();
    _view = AppView.app;
    await _loadPlanOverlayState();
    await Future.wait([_loadModelsAndProviders(), loadProjects()]);
    if (_projects.isNotEmpty) {
      await selectProject(_projects.first.id);
    } else {
      await selectAllProjects();
    }
    startHealthChecks();
    startGitRefresh();
  }

  void _resetServerState() {
    _user = null;
    _users = [];
    _projects = [];
    _projectsOffset = 0;
    _projectsHasMore = true;
    _threads = [];
    _userThreadsOffset = 0;
    _userThreadsHasMore = true;
    _projectThreadOffsets.clear();
    _projectThreadsHasMore.clear();
    _loadingMoreProjectThreads.clear();
    _filesTreeRoot = FileTreeNode.root();
    _filesPanelOpen = false;
    _filesError = '';
    _activeProjectId = null;
    _activeThreadId = null;
    for (final store in _threadStores.values) {
      store.dispose();
    }
    _threadStores.clear();
    _activeStore = null;
    _gitRepoInfo.clear();
    _gitBranches.clear();
    _gitWorktrees.clear();
    _gitConnections = [];
    _linkedMergeRequest = null;
    _composerText = '';
    _attachments.clear();
    _selectedModel = '';
    _selectedPermission = 'normal';
    _runningThreadIds.clear();
    _connectionStatus = ConnectionStatus.checking;
    _page = MainPage.threads;
    _dialog = DialogKind.none;
    _globalError = '';
  }

  static String _serverLabel(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}
