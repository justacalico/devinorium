part of 'package:devinorium_frontend/state/app_state.dart';

mixin AuthStore on AppStateBase {
  bool _switchingServer = false;

  @override
  User? _user;
  @override
  List<User> _users = [];
  @override
  String _totpSecret = '';
  @override
  User? get user => _user;
  @override
  List<User> get users => _users;
  @override
  bool get isOwner => _user?.isOwner ?? false;
  @override
  String get totpSecret => _totpSecret;

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
      await _ensureLocalServer();
      final active = multiServerState.activeApi;
      if (active == null || !(await active.client.isConfigured)) {
        // A local profile whose bundled server failed to start would
        // otherwise sit dead forever — keep the health-check loop running so
        // it can re-ensure and come back.
        if (multiServerState.activeProfile?.isLocal == true) {
          startHealthChecks();
        }
        _view = AppView.app;
        notifyListeners();
        return;
      }
      await _loadUserAndData();
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        if (multiServerState.activeProfile?.isLocal == true) {
          // The bundled server may have restarted with a fresh token while a
          // stale profile survived — re-ensure once before giving up.
          await _ensureLocalServer();
          try {
            await _loadUserAndData();
            return;
          } catch (_) {}
        }
        await multiServerState.clearActiveToken();
      } else {
        _globalError = '$e';
      }
      await _resetServerState();
      if (kIsWeb && e is ApiException && e.statusCode == 401) {
        _dialog = DialogKind.webLogin;
      }
      if (multiServerState.activeProfile?.isLocal == true) {
        startHealthChecks();
      }
      _view = AppView.app;
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
        final prompt = appL10n.totpPrompt;
        notifyListeners();
        return prompt;
      }
      final makeActive = multiServerState.activeServerId == null;
      await multiServerState.addProfile(
        profile.copyWith(isPrimary: makeActive),
        setActive: makeActive,
        api: _apiForNewProfile(),
      );
      if (makeActive) {
        _view = AppView.app;
        notifyListeners();
        await _loadUserAndData();
      }
      _globalError = '';
      notifyListeners();
      return null;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return _globalError;
    }
  }

  @override
  Future<String?> webLogin({
    required String username,
    required String password,
    String? totp,
  }) async {
    _globalError = '';
    notifyListeners();
    try {
      final res = await api.login(
        username: username,
        password: password,
        totp: totp,
      );
      if (res.totpRequired) {
        final prompt = appL10n.totpPrompt;
        notifyListeners();
        return prompt;
      }
      final active = multiServerState.activeProfile;
      final updated = active != null
          ? active.copyWith(
              username: res.username.isNotEmpty
                  ? res.username
                  : username.trim(),
              token: res.token,
            )
          : ServerProfile(
              id: 'web',
              label: 'web',
              baseUrl: '',
              token: res.token,
              username: res.username.isNotEmpty
                  ? res.username
                  : username.trim(),
              createdAt: DateTime.now().toUtc(),
              isPrimary: true,
            );
      await multiServerState.addProfile(
        updated,
        setActive: true,
        api: _apiForNewProfile(),
      );
      _view = AppView.app;
      notifyListeners();
      await _loadUserAndData();
      closeDialog();
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

  /// Spawn the bundled server on desktop and register its profile. No-ops on
  /// web/mobile or when the binary is not bundled (plain `flutter run`).
  @override
  Future<void> _ensureLocalServer() async {
    final manager = localServerManager;
    if (_isDisposed || !manager.isSupported) return;
    try {
      final endpoint = await manager.ensureRunning();
      if (_isDisposed) return;
      if (endpoint != null) {
        final previous = multiServerState.profileById(
          MultiServerState.localProfileId,
        );
        await multiServerState.upsertLocalProfile(
          baseUrl: endpoint.baseUrl,
          token: endpoint.token,
        );
        if (previous != null &&
            (previous.baseUrl != endpoint.baseUrl ||
                previous.token != endpoint.token)) {
          // The bundled server respawned on a new port; open thread stores
          // still hold the dead endpoint, so drop them and let threads
          // reopen against the fresh connection.
          for (final store in _threadStores.values) {
            store.dispose();
          }
          _threadStores.clear();
          _setActiveStore(null);
        }
      } else if (!manager.hasBinary &&
          multiServerState
                  .profileById(MultiServerState.localProfileId)
                  ?.isLocal ==
              true) {
        // The bundled binary vanished (e.g. a dev run without it); drop the
        // stale profile so it does not linger as a dead entry. A transient
        // start failure keeps the profile — health checks retry ensure.
        final wasActive =
            multiServerState.activeServerId == MultiServerState.localProfileId;
        await multiServerState.removeServer(
          MultiServerState.localProfileId,
          force: true,
        );
        if (wasActive) {
          await _resetServerState();
        }
      }
    } catch (e) {
      debugLogFailure('appState.ensureLocalServer', e);
    }
  }

  /// Restart the bundled server when it dies while its profile is active, so
  /// a crash does not leave the app stuck on a dead connection.
  void _onLocalServerExit(int exitCode) {
    debugLogFailure('localServer.exit', 'exit code $exitCode');
    if (multiServerState.activeProfile?.isLocal != true) return;
    unawaited(() async {
      await _ensureLocalServer();
      await checkConnection();
    }());
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
    if (multiServerState.activeApi == null) return;
    final futures = <Future<void>>[
      loadGitConnections(),
      loadCloneRoot(),
      refreshProviderVersion(),
      loadTailscaleStatus(),
    ];
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
    _setActiveStore(null);
    try {
      await api.logout();
    } catch (_) {}
    // Sign-out removes the server profile so no stale unauthenticated
    // connection is left behind. On web the implicit same-origin profile is
    // kept since it is recreated from the registry anyway. The bundled local
    // profile is kept too: it has no credentials to sign out of.
    final activeId = multiServerState.activeServerId;
    final isLocal = multiServerState.activeProfile?.isLocal ?? false;
    if (!kIsWeb && activeId != null && !isLocal) {
      await removeServer(activeId);
    } else if (isLocal) {
      // Nothing to sign out of; just drop the in-memory state and reload.
      await _resetServerState();
      await _loadUserAndData();
    } else {
      await multiServerState.clearActiveToken();
      await _resetServerState();
      if (kIsWeb) {
        _dialog = DialogKind.webLogin;
      }
    }
    _settingsTopicIndex = 0;
    _userMenuOpen = false;
    _view = AppView.app;
    notifyListeners();
  }

  @override
  Future<void> switchServer(String serverId) async {
    if (_switchingServer) return;
    _switchingServer = true;
    stopHealthChecks();
    stopGitRefresh();
    try {
      final ok = await multiServerState.setActiveServer(serverId);
      if (!ok) throw StateError('server not found');
      // The bundled server may have died while a remote profile was active;
      // bring it back before the stored (possibly stale) endpoint is used.
      if (multiServerState.activeProfile?.isLocal == true) {
        await _ensureLocalServer();
      }
      await _resetServerState();
      // Refresh the Tailscale card for the new server even if the rest of
      // the user data load fails below.
      unawaited(loadTailscaleStatus());
      await _loadUserAndData();
    } catch (e) {
      _globalError = '$e';
      // The bundled server is app-managed — keep retrying it even when the
      // switch to it failed, instead of sitting permanently disconnected.
      if (multiServerState.activeProfile?.isLocal == true) {
        startHealthChecks();
      }
      notifyListeners();
    } finally {
      _switchingServer = false;
    }
  }

  @override
  Future<void> removeServer(String serverId) async {
    if (_switchingServer) return;
    // The bundled profile refuses removal; nothing to tear down.
    if (multiServerState.profileById(serverId)?.isLocal == true) return;
    _switchingServer = true;
    try {
      final wasActive = multiServerState.activeServerId == serverId;
      if (wasActive) {
        stopHealthChecks();
        stopGitRefresh();
      }
      await multiServerState.removeServer(serverId);
      if (wasActive) {
        await _resetServerState();
        unawaited(loadTailscaleStatus());
        if (multiServerState.activeProfile?.isLocal == true) {
          await _ensureLocalServer();
        }
        if (multiServerState.activeApi != null) {
          await _loadUserAndData();
        } else {
          if (multiServerState.activeProfile?.isLocal == true) {
            startHealthChecks();
          }
          _view = AppView.app;
          notifyListeners();
        }
      }
    } catch (e) {
      _globalError = '$e';
      if (multiServerState.activeProfile?.isLocal == true) {
        startHealthChecks();
      }
      notifyListeners();
    } finally {
      _switchingServer = false;
    }
  }

  @override
  Future<void> saveProvider({
    String? providerId,
    String? providerCommand,
    Map<String, String>? providerCommands,
  }) async {
    final user = _user;
    if (user == null) return;
    try {
      _user = await api.updateMe(
        providerId: providerId ?? user.providerId,
        providerCommand: providerCommand ?? user.providerCommand,
        providerCommands: providerCommands,
      );
      if (providerId != null && providerId != user.providerId) {
        // The global composer selection followed the old default provider;
        // reset it so new threads start on the new provider's catalog.
        _selectedProvider = '';
        _selectedModel = '';
        _modelsProvider = '';
        _models = [];
        await _saveSelectedProvider('');
        await _saveSelectedModel('');
        await ensureModelsFor(_user!.providerId);
      }
      _globalError = '';
      // The installed version and the availability probe both depend on the
      // provider command, so re-check them whenever the saved config changes.
      final touched = <String>{
        if (providerId != null || providerCommand != null)
          providerId ?? user.providerId,
        ...?providerCommands?.keys,
      };
      for (final id in touched) {
        unawaited(refreshProviderVersion(providerId: id));
      }
      unawaited(_refreshProviders());
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }

  /// Refetch the provider list so availability flags follow the last probe —
  /// e.g. after a command edit or a successful health check.
  Future<void> _refreshProviders() async {
    try {
      _providers = await api.listProviders();
      notifyListeners();
    } catch (_) {
      // Keep the last known list on failure.
    }
  }

  /// Save the CLI command for a single provider without changing the
  /// user's default provider.
  @override
  Future<void> saveProviderCommand(String providerId, String command) async {
    final user = _user;
    if (user == null) return;
    await saveProvider(
      providerId: user.providerId,
      providerCommand: providerId == user.providerId
          ? command
          : user.providerCommand,
      providerCommands: {providerId: command},
    );
  }

  @override
  Future<void> testProvider({
    required String providerId,
    required String command,
  }) async {
    try {
      await api.testProvider(providerId: providerId, command: command);
      _globalError = '';
      // A passing health check means the binary answers; refresh the
      // availability flags without waiting for the server-side TTL.
      unawaited(_refreshProviders());
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
    _user = await api.me();
    await _loadPlanOverlayState();
    await _loadComposerSelections();
    await _loadModelsAndProviders();
    await loadProjects();
    if (_projects.isNotEmpty) {
      await selectProject(_projects.first.id);
    } else {
      await selectAllProjects();
    }
    _view = AppView.app;
    notifyListeners();
    startHealthChecks();
    startGitRefresh();
  }

  Future<void> _resetServerState() async {
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
    _sidebarOpen = false;
    _filesError = '';
    _gitPanelOpen = false;
    _gitPanelChanges = null;
    _gitPanelRepoInfo = null;
    _gitPanelLoading = false;
    _gitActionBusy = false;
    _gitPanelUnsupported = false;
    _gitPanelError = '';
    _gitPanelScopeKey = null;
    _gitPanelThreadId = null;
    _gitPanelProjectId = null;
    // Invalidate any in-flight panel load so its result cannot write stale
    // state from the old server back into the reset fields.
    _gitPanelSeq++;
    _activeProjectId = null;
    _activeThreadId = null;
    for (final store in _threadStores.values) {
      store.dispose();
    }
    _threadStores.clear();
    _setActiveStore(null);
    _gitRepoInfo.clear();
    _gitBranches.clear();
    _gitWorktrees.clear();
    _gitConnections = [];
    _tailscaleInfo = null;
    _tailscaleBusy = false;
    // Invalidate in-flight status loads so a slow response from the old
    // server cannot write back over the reset state.
    _tailscaleSeq++;
    _linkedMergeRequest = null;
    _composerText = '';
    _attachments = [];
    _pathRefs = [];
    _threadReferences = [];
    _selectedModel = '';
    _selectedPermission = 'normal';
    _selectedProvider = '';
    _modelsProvider = '';
    _models = [];
    _modelsByProvider.clear();
    _providers = [];
    await _saveSelectedProvider('');
    await _saveSelectedModel('');
    await _saveSelectedPermission('');
    _providerVersions.clear();
    _runningThreadIds.clear();
    _connectionStatus = ConnectionStatus.checking;
    _serverVersion = null;
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
