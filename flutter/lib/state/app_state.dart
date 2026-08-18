import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../models/composer_mode.dart';
import '../models/models.dart';
import 'async_value.dart';
import 'streaming_state.dart';
import 'thread_store.dart';

enum AppView { loading, login, app }

enum MainPage { threads, settings }

enum DialogKind { none, totpSetup, newProject, permissionRequest, gitBranches }

/// Central app state.
class AppState extends ChangeNotifier {
  final ApiService api;

  AppState({ApiService? api}) : api = api ?? ApiService();

  /// Test-only constructor to pre-populate state without running a full flow.
  AppState.test({
    ApiService? api,
    User? user,
    List<User> users = const [],
    List<Project> projects = const [],
    List<Thread> threads = const [],
    List<ThreadGroup> groups = const [],
    List<ModelInfo> models = const [],
    List<ProviderInfo> providers = const [],
    List<GitConnection> gitConnections = const [],
    bool loadingGitConnections = false,
    int? activeProjectId,
    String? activeThreadId,
    ThreadDetail? activeThreadDetail,
    DialogKind? dialog,
    PermissionRequest? pendingPermissionRequest,
    List<String> filesPath = const [],
    String? globalError,
    ThemeMode? themeMode,
    Locale? locale,
    int? settingsTopicIndex,
    bool sending = false,
    String? lastRunStatus,
    List<MessagePart> streamingParts = const [],
    bool streamingThinkingActive = false,
    ComposerMode composerMode = ComposerMode.code,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    String? selectedModel,
    String? selectedPermission,
  }) : api = api ?? ApiService() {
    _themeMode = themeMode ?? ThemeMode.system;
    _locale = locale ?? const Locale('en');
    _settingsTopicIndex = settingsTopicIndex ?? 0;
    _gitConnections = List<GitConnection>.from(gitConnections);
    _loadingGitConnections = loadingGitConnections;
    _user = user;
    _users = users;
    _projects = projects;
    _threads = threads;
    _groups = groups;
    _models = models;
    _providers = providers;
    _activeProjectId = activeProjectId;
    _dialog = dialog ?? DialogKind.none;
    _filesPath = filesPath;
    _globalError = globalError ?? '';
    _composerMode = composerMode;

    final threadId = activeThreadId ?? activeThreadDetail?.thread.id;
    if (threadId != null) {
      final detail = activeThreadDetail;
      final projectId = activeProjectId ?? detail?.thread.projectId ?? 0;
      final streaming = StreamingSnapshot(
        phase: sending || streamingParts.isNotEmpty || streamingThinkingActive
            ? StreamPhase.running
            : StreamPhase.idle,
        parts: streamingParts,
        thinkingActive: streamingThinkingActive,
        pendingPermission: pendingPermissionRequest,
      );
      final store = ThreadStore(
        api: this.api,
        threadId: threadId,
        projectId: projectId,
        detail: detail != null ? AsyncValue.ready(detail) : null,
        streaming: streaming,
        composerText: composerText ?? '',
        attachments: attachments,
        composerMode: composerMode,
        selectedModel: selectedModel ?? '',
        selectedPermission: selectedPermission ?? 'normal',
        lastRunStatus: lastRunStatus,
      );
      _threadStores[threadId] = store;
      _setActiveStore(store);
    } else {
      _activeThreadId = activeThreadId;
      _composerText = composerText ?? '';
      _attachments.addAll(attachments);
      _selectedModel = selectedModel ?? '';
      _selectedPermission = selectedPermission ?? 'normal';
    }
  }

  @override
  void dispose() {
    for (final store in _threadStores.values) {
      store.dispose();
    }
    _threadStores.clear();
    _activeStore = null;
    super.dispose();
  }

  AppView _view = AppView.loading;
  MainPage _page = MainPage.threads;
  User? _user;
  List<Project> _projects = [];
  List<Thread> _threads = [];
  final Set<String> _runningThreadIds = {};
  List<ThreadGroup> _groups = [];
  List<ModelInfo> _models = [];
  List<ProviderInfo> _providers = [];
  int? _activeProjectId;
  String? _activeThreadId;
  List<User> _users = [];
  List<Device> _devices = [];
  String _loginError = '';
  bool _showTotpField = false;
  bool _userMenuOpen = false;
  bool _filesPanelOpen = false;
  List<String> _filesPath = [];
  List<DirEntry> _filesEntries = [];
  String _filesError = '';
  DialogKind _dialog = DialogKind.none;
  String _totpSecret = '';

  // Default draft/selection state used when no thread is active.
  String _composerText = '';
  final List<({String filename, String mime, Uint8List bytes})> _attachments =
      [];
  String _selectedModel = '';
  String _selectedPermission = 'normal';
  ComposerMode _composerMode = ComposerMode.code;

  // Thread stores: one per thread id. Active store is the currently focused
  // thread; all others are kept warm so switching back preserves draft state.
  final Map<String, ThreadStore> _threadStores = {};
  ThreadStore? _activeStore;

  String _globalError = '';
  String _lastThreadError = '';
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');
  int _settingsTopicIndex = 0;

  // Git state (per project).
  final Map<int, GitRepoInfo> _gitRepoInfo = {};
  final Map<int, List<GitBranch>> _gitBranches = {};
  final Map<int, List<GitWorktree>> _gitWorktrees = {};
  int? _gitDialogProjectId;

  // Git host connections.
  List<GitConnection> _gitConnections = [];
  bool _loadingGitConnections = false;

  // Getters
  AppView get view => _view;
  MainPage get page => _page;
  User? get user => _user;
  List<Project> get projects => _projects;
  List<Thread> get threads => _threads;
  Set<String> get runningThreadIds => _runningThreadIds;
  List<ThreadGroup> get groups => _groups;
  List<ModelInfo> get models => _models;
  List<ProviderInfo> get providers => _providers;
  int? get activeProjectId => _activeProjectId;

  String? get activeThreadId => _activeThreadId;
  ThreadDetail? get activeThreadDetail => _activeStore?.detail.valueOrNull;
  List<User> get users => _users;
  List<Device> get devices => _devices;
  bool get isOwner => _user?.isOwner ?? false;
  String get loginError => _loginError;
  bool get showTotpField => _showTotpField;
  bool get userMenuOpen => _userMenuOpen;
  bool get filesPanelOpen => _filesPanelOpen;
  List<String> get filesPath => _filesPath;
  List<DirEntry> get filesEntries => _filesEntries;
  String get filesError => _filesError;
  DialogKind get dialog => _dialog;
  String get totpSecret => _totpSecret;
  String get composerText => _activeStore?.composerText ?? _composerText;
  bool get sending => _activeStore?.sending ?? false;
  String? get lastRunStatus => _activeStore?.lastRunStatus;
  List<({String filename, String mime, Uint8List bytes})> get attachments =>
      _activeStore?.attachments ?? _attachments;
  String get selectedModel => _activeStore?.selectedModel ?? _selectedModel;
  String get selectedPermission =>
      _activeStore?.selectedPermission ?? _selectedPermission;
  ComposerMode get composerMode => _activeStore?.composerMode ?? _composerMode;
  List<MessagePart> get streamingParts =>
      _activeStore?.streamingParts ?? const [];
  bool get streamingThinkingActive =>
      _activeStore?.streamingThinkingActive ?? false;
  PermissionRequest? get pendingPermissionRequest =>
      _activeStore?.pendingPermissionRequest;
  String get globalError => _globalError;
  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;
  int get settingsTopicIndex => _settingsTopicIndex;

  void _setActiveStore(ThreadStore? store) {
    if (_activeStore == store) return;
    _activeStore?.onStateChanged = null;
    _activeStore?.cancelStream();
    _activeStore?.clearStreamingState();
    _activeStore = store;
    _activeThreadId = store?.threadId;
    store?.onStateChanged = _onThreadStoreChanged;
    _syncFromActiveStore();
    notifyListeners();
  }

  void _onThreadStoreChanged() {
    final store = _activeStore;
    if (store == null) return;
    _syncFromActiveStore();
    notifyListeners();
  }

  void _syncFromActiveStore() {
    final store = _activeStore;
    if (store == null) return;
    final previousThreadError = _lastThreadError;
    var error = '';
    if (store.globalError.isNotEmpty) {
      error = store.globalError;
    } else if (store.streaming.error != null &&
        store.streaming.error!.isNotEmpty) {
      error = store.streaming.error!;
    }
    if (error.isNotEmpty) {
      _globalError = error;
      _lastThreadError = error;
    } else {
      _lastThreadError = '';
      if (_globalError == previousThreadError) {
        _globalError = '';
      }
    }
    if (store.pendingPermissionRequest != null) {
      _dialog = DialogKind.permissionRequest;
    } else if (_dialog == DialogKind.permissionRequest) {
      _dialog = DialogKind.none;
    }
  }

  ThreadStore _createStore(
    String id, {
    int? projectId,
    ThreadDetail? detail,
    StreamingSnapshot? streaming,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
    ComposerMode? composerMode,
    String? selectedModel,
    String? selectedPermission,
  }) {
    return ThreadStore(
      api: api,
      threadId: id,
      projectId: projectId ?? _activeProjectId ?? 0,
      detail: detail != null ? AsyncValue.ready(detail) : null,
      streaming: streaming,
      composerText: composerText,
      attachments: attachments,
      composerMode: composerMode,
      selectedModel: selectedModel,
      selectedPermission: selectedPermission,
    );
  }

  GitRepoInfo? gitRepoInfo(int projectId) => _gitRepoInfo[projectId];
  List<GitBranch> gitBranches(int projectId) => _gitBranches[projectId] ?? [];
  List<GitWorktree> gitWorktrees(int projectId) =>
      _gitWorktrees[projectId] ?? [];
  int? get gitDialogProjectId => _gitDialogProjectId;

  List<GitConnection> get gitConnections => _gitConnections;
  bool get loadingGitConnections => _loadingGitConnections;

  // ---- Setters / mutations ----

  void setView(AppView v) {
    _view = v;
    notifyListeners();
  }

  void setPage(MainPage p) {
    _page = p;
    notifyListeners();
  }

  void setSettingsTopicIndex(int index) {
    _settingsTopicIndex = index;
    notifyListeners();
  }

  void toggleUserMenu() {
    _userMenuOpen = !_userMenuOpen;
    notifyListeners();
  }

  void setUserMenuOpen(bool v) {
    _userMenuOpen = v;
    notifyListeners();
  }

  void setComposerText(String t) {
    final store = _activeStore;
    if (store != null) {
      store.composerText = t;
    } else {
      _composerText = t;
    }
    notifyListeners();
  }

  void addAttachments(
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    final store = _activeStore;
    if (store != null) {
      store.attachments.addAll(files);
    } else {
      _attachments.addAll(files);
    }
    notifyListeners();
  }

  void removeAttachment(int index) {
    final store = _activeStore;
    if (store != null) {
      store.attachments.removeAt(index);
    } else {
      _attachments.removeAt(index);
    }
    notifyListeners();
  }

  void clearAttachments() {
    final store = _activeStore;
    if (store != null) {
      store.attachments.clear();
    } else {
      _attachments.clear();
    }
    notifyListeners();
  }

  void setSelectedModel(String m) {
    final store = _activeStore;
    if (store != null) {
      store.selectedModel = m;
    } else {
      _selectedModel = m;
    }
    notifyListeners();
  }

  void setSelectedPermission(String p) {
    final store = _activeStore;
    if (store != null) {
      store.selectedPermission = p;
    } else {
      _selectedPermission = p;
    }
    notifyListeners();
  }

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

  Future<void> _saveComposerMode(ComposerMode m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_composer_mode', m.name);
    } catch (_) {}
  }

  Future<void> _loadComposerMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_composer_mode');
      _composerMode = ComposerModeX.fromString(value);
    } catch (_) {}
    notifyListeners();
  }

  void setLoginError(String e) {
    _loginError = e;
    notifyListeners();
  }

  void setShowTotpField(bool v) {
    _showTotpField = v;
    notifyListeners();
  }

  void setGlobalError(String e) {
    _globalError = e;
    notifyListeners();
  }

  void clearGlobalError() {
    _globalError = '';
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_theme_mode', _themeModeToString(mode));
    } catch (_) {}
  }

  static String _themeModeToString(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
  }

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_theme_mode') ?? 'system';
      _themeMode = _parseThemeMode(value);
    } catch (_) {
      _themeMode = ThemeMode.system;
    }
    notifyListeners();
  }

  static ThemeMode _parseThemeMode(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setLanguage(String language) async {
    _locale = Locale(language);
    setAppL10n(_locale);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_language', language);
    } catch (_) {}
  }

  Future<void> _loadLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_language') ?? 'en';
      _locale = Locale(value);
    } catch (_) {
      _locale = const Locale('en');
    }
    setAppL10n(_locale);
    notifyListeners();
  }

  Future<void> openFilesPanel() async {
    _filesPanelOpen = true;
    _filesPath = [];
    _filesError = '';
    notifyListeners();
    await reloadFiles();
  }

  void closeFilesPanel() {
    _filesPanelOpen = false;
    notifyListeners();
  }

  Future<void> navigateFilesInto(String name) async {
    _filesPath = [..._filesPath, name];
    notifyListeners();
    await reloadFiles();
  }

  Future<void> navigateFilesTo(List<String> path) async {
    _filesPath = path;
    notifyListeners();
    await reloadFiles();
  }

  Future<void> reloadFiles() async {
    final path = _filesPath.join('/');
    try {
      _filesEntries = await api.listFiles(
        path: path.isEmpty ? null : path,
        projectId: _activeProjectId,
      );
      _filesError = '';
    } catch (e) {
      _filesError = '$e';
    }
    notifyListeners();
  }

  Future<void> mkdir(String name) async {
    final p = _filesPath.join('/');
    final full = p.isEmpty ? name.trim() : '$p/${name.trim()}';
    try {
      await api.mkdir(full, projectId: _activeProjectId);
      _filesError = '';
      notifyListeners();
      await reloadFiles();
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteFile(String name, {bool skipConfirm = false}) async {
    final p = _filesPath.join('/');
    final full = p.isEmpty ? name : '$p/$name';
    try {
      await api.deleteFile(full, projectId: _activeProjectId);
      _filesError = '';
      notifyListeners();
      await reloadFiles();
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }

  // ---- Auth ----

  Future<void> _loadModelsAndProviders() async {
    await Future.wait([
      (() async {
        try {
          _models = await api.listModels();
          if (_models.isNotEmpty && _selectedModel.isEmpty) {
            _selectedModel = _models.first.id;
          }
        } catch (_) {}
      })(),
      (() async {
        try {
          _providers = await api.listProviders();
        } catch (_) {}
      })(),
    ]);
  }

  Future<void> bootstrap() async {
    await _loadThemeMode();
    await _loadLanguage();
    await _loadComposerMode();
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
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        await api.client.clearCredentials();
      }
      _view = AppView.login;
      notifyListeners();
    }
  }


  Future<void> loadProjects() async {
    try {
      _projects = await api.listProjects();
    } catch (_) {
      _projects = [];
    }
  }

  Future<void> refreshThreadsAndGroups() async {
    await Future.wait([
      (() async {
        try {
          _threads = await api.listThreads();
        } catch (_) {}
      })(),
      (() async {
        try {
          _groups = await api.listThreadGroups();
        } catch (_) {}
      })(),
    ]);
    notifyListeners();
    unawaited(refreshRunningThreads());
  }

  Future<void> refreshRunningThreads() async {
    if (_threads.isEmpty) {
      _runningThreadIds.clear();
      notifyListeners();
      return;
    }

    final results = await Future.wait(
      _threads.map((t) async {
        try {
          final run = await api.getThreadRun(t.id);
          return (t.id, run['status'] as String? ?? 'idle');
        } catch (_) {
          return (t.id, 'idle');
        }
      }),
    );

    _runningThreadIds
      ..clear()
      ..addAll(results.where((r) => r.$2 == 'running').map((r) => r.$1));
    notifyListeners();
  }

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
      await Future.wait([_loadModelsAndProviders(), loadProjects()]);
      if (_projects.isNotEmpty) {
        await selectProject(_projects.first.id);
      } else {
        await selectAllProjects();
      }
    } catch (e) {
      _view = AppView.login;
      _loginError = '$e';
      notifyListeners();
    }
  }

  Future<void> loadUsers() async {
    try {
      _users = await api.listUsers();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }

  Future<void> loadDevices() async {
    try {
      _devices = await api.listDevices();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
  }

  /// Load all settings data in parallel so the settings tabs appear at once
  /// instead of making the user wait for three sequential round trips.
  Future<void> loadSettingsData() async {
    final futures = <Future<void>>[
      loadDevices(),
      loadGitConnections(),
    ];
    if (isOwner) {
      futures.add(loadUsers());
    }
    await Future.wait(futures);
  }

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

  Future<void> logout() async {
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
    _activeProjectId = null;
    _showTotpField = false;
    _loginError = '';
    _composerText = '';
    _composerMode = ComposerMode.code;
    _attachments.clear();
    _selectedModel = '';
    _selectedPermission = 'normal';
    _runningThreadIds.clear();
    notifyListeners();
  }

  // ---- Projects ----

  Future<void> selectProject(int id) async {
    if (_activeThreadId == null) {
      _activeProjectId = id;
    }
    _page = MainPage.threads;
    _globalError = '';
    notifyListeners();
    await refreshThreadsAndGroups();
    unawaited(loadGitRepoInfo(id));
  }

  Future<void> selectAllProjects() async {
    if (_activeThreadId == null) {
      _activeProjectId = null;
    }
    _page = MainPage.threads;
    _globalError = '';
    notifyListeners();
    await refreshThreadsAndGroups();
  }

  Future<void> createProject({
    required String name,
    required String path,
  }) async {
    _globalError = '';
    notifyListeners();
    try {
      final p = await api.createProject(name: name, path: path);
      _projects = [..._projects, p];
      _activeProjectId = p.id;
      _setActiveStore(null);
      _page = MainPage.threads;
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteProject(int id) async {
    try {
      await api.deleteProject(id);
      _projects = _projects.where((p) => p.id != id).toList();
      if (_activeProjectId == id) {
        _setActiveStore(null);
        if (_projects.isNotEmpty) {
          _activeProjectId = _projects.first.id;
        } else {
          _activeProjectId = null;
        }
      }
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> reorderProjects(List<int> ids) async {
    final oldProjects = _projects;
    final map = <int, Project>{};
    for (final p in oldProjects) {
      map[p.id] = p;
    }
    _projects = ids.map((id) => map[id]!).toList();
    notifyListeners();

    try {
      await api.reorderProjects(ids);
    } catch (e) {
      _projects = oldProjects;
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> openNewProjectDialog() async {
    _dialog = DialogKind.newProject;
    _userMenuOpen = false;
    notifyListeners();
  }

  // ---- Threads ----

  Future<void> createNewThread({int? projectId}) async {
    final targetId = projectId ?? _activeProjectId;
    if (targetId == null) {
      _globalError = appL10n.selectProjectFirst;
      notifyListeners();
      return;
    }
    if (targetId != _activeProjectId) {
      _setActiveStore(null);
      _activeProjectId = targetId;
      _page = MainPage.threads;
      notifyListeners();
    } else {
      _setActiveStore(null);
    }
    _page = MainPage.threads;
    _composerText = '';
    _attachments.clear();
    notifyListeners();
    try {
      final t = await api.createThread(
        projectId: targetId,
        title: appL10n.newThread,
        model: _selectedModel.isEmpty ? null : _selectedModel,
        permissionMode: _selectedPermission,
      );
      final store = _createStore(
        t.id,
        projectId: targetId,
        composerMode: _composerMode,
        selectedModel: _selectedModel,
        selectedPermission: _selectedPermission,
      );
      _threadStores[t.id] = store;
      _setActiveStore(store);
      await store.load();
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> openThread(String id) async {
    final previous = _threadStores[id];
    _setActiveStore(null);
    _activeThreadId = id;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.getThread(id, includeMessages: true),
        api.getThreadProject(id),
      ]);
      final detail = results[0] as ThreadDetail;
      notifyListeners();

      // Discover the thread's project and switch the active project.
      var projectId = detail.thread.projectId;
      try {
        final info = results[1] as Map<String, dynamic>;
        final apiProjectId = (info['project_id'] as num).toInt();
        if (apiProjectId != 0) {
          projectId = apiProjectId;
        }
      } catch (_) {}
      _activeProjectId = projectId;

      // Load the threads list for the active project.
      _globalError = '';
      await refreshThreadsAndGroups();

      // Create or replace the thread store with the latest detail.
      // Preserve the user's draft from a previous visit so switching
      // threads does not lose in-progress input.
      final store = _createStore(
        id,
        detail: detail,
        projectId: projectId,
        composerText: previous?.composerText ?? '',
        attachments: previous?.attachments,
        composerMode: previous?.composerMode ?? _composerMode,
        selectedModel: detail.thread.model,
        selectedPermission: detail.thread.permissionMode,
      );
      _threadStores[id] = store;
      _setActiveStore(store);
      previous?.dispose();

      // If the backend is already running this thread, reconnect to it.
      await store.resume();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

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

  Future<void> saveThreadSettings() async {
    final store = _activeStore;
    if (store == null) return;
    try {
      await store.saveSettings();
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteThread(String id) async {
    try {
      await api.deleteThread(id);
      final store = _threadStores.remove(id);
      if (store != null) store.markDeleted();
      if (_activeStore?.threadId == id) {
        _setActiveStore(null);
      }
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteThreadGroup(int id) async {
    try {
      await api.deleteThreadGroup(id);
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> loadMoreMessages() async {
    final store = _activeStore;
    if (store == null) return;
    try {
      await store.loadMoreMessages();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> resumeThread(String id) async {
    ThreadStore? store = _threadStores[id];
    if (store == null) {
      store = _createStore(id);
      _threadStores[id] = store;
    }
    _setActiveStore(store);
    try {
      await store.resume();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> sendMessage() async {
    final store = _activeStore;
    if (store == null) return;
    if (store.composerText.trim().isEmpty) return;
    await store.sendMessage();
  }

  Future<void> stopThread() async {
    final store = _activeStore;
    if (store == null || !store.sending) return;
    await store.stop();
  }

  // ---- TOTP ----

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

  Future<void> respondToPermissionRequest(String? optionId) async {
    final store = _activeStore;
    if (store == null) return;
    try {
      await store.respondToPermissionRequest(optionId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  // ---- Git ----

  Future<void> loadGitRepoInfo(int projectId) async {
    try {
      final info = await api.gitRepoStatus(projectId);
      _gitRepoInfo[projectId] = info;
      _globalError = '';
      _syncProjectBranch(projectId, info);
    } catch (e) {
      // 404 / not a repo is not an error; clear the state.
      _gitRepoInfo.remove(projectId);
    }
    notifyListeners();
  }

  void _syncProjectBranch(int projectId, GitRepoInfo info) {
    final idx = _projects.indexWhere((p) => p.id == projectId);
    if (idx == -1) return;
    _projects = [
      ..._projects.sublist(0, idx),
      _projects[idx].copyWith(isRepo: info.isRepo, gitBranch: info.branch),
      ..._projects.sublist(idx + 1),
    ];
  }

  Future<void> loadGitBranches(int projectId, {String? query}) async {
    try {
      final branches = await api.gitBranches(projectId, query: query);
      _gitBranches[projectId] = branches;
      _globalError = '';
    } catch (e) {
      _gitBranches.remove(projectId);
    }
    notifyListeners();
  }

  Future<void> loadGitWorktrees(int projectId) async {
    try {
      final worktrees = await api.gitWorktrees(projectId);
      _gitWorktrees[projectId] = worktrees;
      _globalError = '';
    } catch (e) {
      _gitWorktrees.remove(projectId);
    }
    notifyListeners();
  }

  Future<void> openGitBranchDialog(int projectId) async {
    _gitDialogProjectId = projectId;
    _dialog = DialogKind.gitBranches;
    _userMenuOpen = false;
    await loadGitRepoInfo(projectId);
    if (gitRepoInfo(projectId)?.isRepo ?? false) {
      await loadGitBranches(projectId);
      await loadGitWorktrees(projectId);
    }
    notifyListeners();
  }

  Future<void> gitCreateBranch(
    int projectId,
    String name, {
    String? base,
    bool switchBranch = false,
  }) async {
    try {
      await api.gitCreateBranch(
        projectId,
        name,
        base: base,
        switchBranch: switchBranch,
      );
      _globalError = '';
      await loadGitBranches(projectId);
      await loadGitRepoInfo(projectId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitCheckout(
    int projectId,
    String refName, {
    bool track = false,
  }) async {
    try {
      await api.gitCheckout(projectId, refName, track: track);
      _globalError = '';
      await loadGitRepoInfo(projectId);
      await loadGitBranches(projectId);
      await loadGitWorktrees(projectId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPull(int projectId) async {
    try {
      await api.gitPull(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId);
      await loadGitBranches(projectId);
      await loadGitWorktrees(projectId);
      await loadProjects();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPullBranch(int projectId, String name) async {
    try {
      await api.gitPullBranch(projectId, name);
      _globalError = '';
      await loadGitRepoInfo(projectId);
      await loadGitBranches(projectId);
      await loadGitWorktrees(projectId);
      await loadProjects();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPush(int projectId) async {
    try {
      await api.gitPush(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId);
      await loadGitBranches(projectId);
      await loadGitWorktrees(projectId);
      await loadProjects();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitCreateWorktree(
    int projectId,
    String name,
    String base, {
    bool newBranch = false,
  }) async {
    try {
      await api.gitCreateWorktree(projectId, name, base, newBranch: newBranch);
      _globalError = '';
      await loadGitWorktrees(projectId);
      if (newBranch) {
        await loadGitBranches(projectId);
      }
      await loadGitRepoInfo(projectId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitDeleteWorktree(int projectId, String worktreePath) async {
    try {
      await api.gitDeleteWorktree(projectId, worktreePath);
      _globalError = '';
      await loadGitWorktrees(projectId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> setThreadGit(
    String threadId, {
    String? branch,
    String? worktreePath,
  }) async {
    try {
      await api.updateThreadGit(
        threadId,
        branch: branch,
        worktreePath: worktreePath,
      );
      _globalError = '';
      await refreshThreadsAndGroups();
      if (_activeStore?.threadId == threadId) {
        await _activeStore?.reloadDetail();
      }
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  // ---- Git connections ----

  Future<void> loadGitConnections() async {
    _loadingGitConnections = true;
    notifyListeners();
    try {
      _gitConnections = await api.listGitConnections();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    } finally {
      _loadingGitConnections = false;
      notifyListeners();
    }
  }

  Future<void> connectGitLab({required String token, String? hostname}) async {
    try {
      final updated = await api.connectGitLab(token: token, hostname: hostname);
      final index = _gitConnections.indexWhere((c) => c.id == updated.id);
      if (index >= 0) {
        _gitConnections[index] = updated;
      } else {
        _gitConnections.add(updated);
      }
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> disconnectGitLab({String? hostname}) async {
    try {
      await api.disconnectGitLab(hostname: hostname);
      await loadGitConnections();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  void closeDialog() {
    _dialog = DialogKind.none;
    _gitDialogProjectId = null;
    notifyListeners();
  }
}
