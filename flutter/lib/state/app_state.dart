import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../issue/gitlab_issue_provider.dart';
import '../l10n/global_l10n.dart';
import '../merge_request/gitlab_merge_request_provider.dart';
import '../models/composer_mode.dart';
import '../utils/link_opener.dart' as link_opener;
import '../models/models.dart';
import '../services/notification_service.dart';
import 'async_value.dart';
import 'streaming_state.dart';
import 'thread_store.dart';

enum AppView { loading, login, app }

enum MainPage { threads, settings }

enum ConnectionStatus { connected, disconnected, checking }

enum DialogKind {
  none,
  totpSetup,
  newProject,
  permissionRequest,
  gitBranches,
  renameProject,
  renameThread,
  mergeRequest,
  issue,
}

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
    String? cloneRoot,
    Map<int, GitRepoInfo> gitRepoInfo = const {},
    MergeRequestLink? linkedMergeRequest,
    int? activeProjectId,
    String? activeThreadId,
    ThreadDetail? activeThreadDetail,
    DialogKind? dialog,
    String? mergeRequestUrl,
    String? issueUrl,
    PermissionRequest? pendingPermissionRequest,
    AskRequest? pendingAskRequest,
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
    String? startedAt,
    bool threadLoading = false,
    ConnectionStatus connectionStatus = ConnectionStatus.connected,
  }) : api = api ?? ApiService() {
    _themeMode = themeMode ?? ThemeMode.system;
    _locale = locale ?? const Locale('en');
    _settingsTopicIndex = settingsTopicIndex ?? 0;
    _gitConnections = List<GitConnection>.from(gitConnections);
    _loadingGitConnections = loadingGitConnections;
    _cloneRoot = cloneRoot;
    _gitRepoInfo.addAll(gitRepoInfo);
    _linkedMergeRequest = linkedMergeRequest;
    _user = user;
    _users = users;
    _projects = projects;
    _projectsOffset = projects.length;
    _projectsHasMore = false;
    _threads = threads;
    _userThreadsOffset = threads.length;
    _userThreadsHasMore = false;
    if (activeProjectId != null) {
      final projectThreadCount = threads
          .where((t) => t.projectId == activeProjectId)
          .length;
      _projectThreadOffsets[activeProjectId] = projectThreadCount;
      _projectThreadsHasMore[activeProjectId] =
          projectThreadCount == 0 || projectThreadCount >= _threadChunkSize;
    }
    _groups = groups;
    _models = models;
    _providers = providers;
    _activeProjectId = activeProjectId;
    _dialog = dialog ?? DialogKind.none;
    _mergeRequestUrl = mergeRequestUrl;
    _issueUrl = issueUrl;
    _filesPath = filesPath;
    _globalError = globalError ?? '';
    _composerMode = composerMode;
    _connectionStatus = connectionStatus;

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
        pendingAsk: pendingAskRequest,
        startedAt: startedAt,
      );
      final store = ThreadStore(
        api: this.api,
        threadId: threadId,
        projectId: projectId,
        detail: detail != null ? AsyncValue.ready(detail) : null,
        status: threadLoading ? ThreadStoreStatus.loading : null,
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
    _healthTimer?.cancel();
    _gitRefreshTimer?.cancel();
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

  // Pagination state for list endpoints.
  static const int _projectChunkSize = 50;
  int _projectsOffset = 0;
  bool _projectsHasMore = true;
  bool _loadingMoreProjects = false;

  static const int _threadChunkSize = 50;
  int _userThreadsOffset = 0;
  bool _userThreadsHasMore = true;
  bool _loadingMoreUserThreads = false;
  final Map<int, int> _projectThreadOffsets = {};
  final Map<int, bool> _projectThreadsHasMore = {};
  final Map<int, bool> _loadingMoreProjectThreads = {};

  static const int _fileChunkSize = 100;
  int _filesOffset = 0;
  bool _filesHasMore = true;
  bool _loadingMoreFiles = false;

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
  bool _planOverlayVisible = false;
  bool _planOverlayExpanded = false;
  bool _planOverlayUserDismissed = false;
  List<String> _filesPath = [];
  List<DirEntry> _filesEntries = [];
  String _filesError = '';
  DialogKind _dialog = DialogKind.none;
  String? _mergeRequestUrl;
  String? _issueUrl;
  String _totpSecret = '';
  bool _threadOpening = false;

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
  final _notifications = NotificationService();

  // Git state (per project).
  final Map<int, GitRepoInfo> _gitRepoInfo = {};
  final Map<int, List<GitBranch>> _gitBranches = {};
  final Map<int, List<GitWorktree>> _gitWorktrees = {};
  int? _gitDialogProjectId;

  // Linked merge request for the active thread's branch.
  MergeRequestLink? _linkedMergeRequest;
  bool _loadingLinkedMergeRequest = false;
  // The (project, branch) the in-flight lookup is for, so a slow response
  // cannot overwrite the state for a newer thread/branch.
  int? _linkedMrProjectId;
  String? _linkedMrBranch;

  // Rename dialog state.
  int? _renameProjectId;
  String? _renameThreadId;
  String _renameInitialName = '';

  // Git host connections.
  List<GitConnection> _gitConnections = [];
  bool _loadingGitConnections = false;

  // Clone root.
  String? _cloneRoot;
  bool _loadingCloneRoot = false;

  // Connection health.
  ConnectionStatus _connectionStatus = ConnectionStatus.checking;
  Timer? _healthTimer;
  Timer? _gitRefreshTimer;
  bool _refreshingGit = false;

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
  bool get activeThreadLoading =>
      _threadOpening || _activeStore?.status == ThreadStoreStatus.loading;
  List<User> get users => _users;
  List<Device> get devices => _devices;
  bool get isOwner => _user?.isOwner ?? false;
  String get loginError => _loginError;
  bool get showTotpField => _showTotpField;
  bool get userMenuOpen => _userMenuOpen;
  bool get filesPanelOpen => _filesPanelOpen;
  bool get planOverlayVisible => _planOverlayVisible;
  bool get planOverlayExpanded => _planOverlayExpanded;
  bool get planOverlayDismissed => _planOverlayUserDismissed;
  Plan? get activePlan => _activeStore?.plan;
  List<String> get filesPath => _filesPath;
  List<DirEntry> get filesEntries => _filesEntries;
  String get filesError => _filesError;
  DialogKind get dialog => _dialog;
  String? get mergeRequestUrl => _mergeRequestUrl;
  String? get issueUrl => _issueUrl;
  MergeRequestLink? get linkedMergeRequest => _linkedMergeRequest;
  bool get loadingLinkedMergeRequest => _loadingLinkedMergeRequest;
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
  AskRequest? get pendingAskRequest => _activeStore?.pendingAskRequest;
  String? get startedAt => _activeStore?.startedAt;
  String get globalError => _globalError;
  ConnectionStatus get connectionStatus => _connectionStatus;
  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;
  int get settingsTopicIndex => _settingsTopicIndex;
  bool get notificationsEnabled => _notifications.notificationsEnabled;

  bool get hasMoreProjects => _projectsHasMore;
  bool get isLoadingMoreProjects => _loadingMoreProjects;
  bool get hasMoreThreads => _userThreadsHasMore;
  bool get isLoadingMoreThreads => _loadingMoreUserThreads;

  bool get hasMoreFiles => _filesHasMore;
  bool get isLoadingMoreFiles => _loadingMoreFiles;

  String? get cloneRoot => _cloneRoot;
  bool get loadingCloneRoot => _loadingCloneRoot;

  bool hasMoreProjectThreads(int projectId) =>
      _projectThreadsHasMore[projectId] ?? false;
  bool isLoadingMoreProjectThreads(int projectId) =>
      _loadingMoreProjectThreads[projectId] ?? false;

  int? get renameProjectId => _renameProjectId;
  String? get renameThreadId => _renameThreadId;
  String get renameInitialName => _renameInitialName;

  void _setActiveStore(ThreadStore? store) {
    if (_activeStore == store) return;
    _activeStore?.onStateChanged = null;
    _activeStore?.cancelStream();
    _activeStore?.clearStreamingState();
    _activeStore = store;
    _activeThreadId = store?.threadId;
    _planOverlayVisible = false;
    _planOverlayExpanded = false;
    _planOverlayUserDismissed = false;
    store?.onStateChanged = _onThreadStoreChanged;
    _syncFromActiveStore();
    _clearLinkedMergeRequest();
    notifyListeners();
  }

  void _clearLinkedMergeRequest() {
    _linkedMergeRequest = null;
    _loadingLinkedMergeRequest = false;
    _linkedMrProjectId = null;
    _linkedMrBranch = null;
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

    // Auto-open the plan overlay when a plan first appears for this thread,
    // unless the user explicitly dismissed it.
    if (!_planOverlayUserDismissed &&
        !_planOverlayVisible &&
        store.plan != null &&
        store.plan!.steps.isNotEmpty) {
      _planOverlayVisible = true;
      _planOverlayExpanded = true;
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
    final store = ThreadStore(
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
    store.onRunFinished = (failed) {
      final title = _threadTitle(id) ?? 'Thread';
      _notifications.notifyThreadCompleted(title: title, failed: failed);
      final projectId = store.projectId;
      if (projectId > 0) {
        unawaited(_refreshGitForProject(projectId));
      }
      unawaited(loadProjects());
    };
    return store;
  }

  String? _threadTitle(String id) {
    for (final t in _threads) {
      if (t.id == id) return t.title;
    }
    return null;
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

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notifications.setNotificationsEnabled(enabled);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('devinorium_notifications', enabled);
    } catch (_) {}
  }

  Future<void> _loadNotificationPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _notifications.setNotificationsEnabled(
        prefs.getBool('devinorium_notifications') ?? false,
      );
    } catch (_) {}
    notifyListeners();
  }

  Future<void> openFilesPanel() async {
    _filesPanelOpen = true;
    _filesPath = [];
    _filesOffset = 0;
    _filesHasMore = true;
    _filesError = '';
    notifyListeners();
    await reloadFiles();
  }

  void closeFilesPanel() {
    _filesPanelOpen = false;
    notifyListeners();
  }

  void openPlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayExpanded = true;
    _planOverlayUserDismissed = false;
    notifyListeners();
  }

  void dismissPlanOverlay() {
    _planOverlayVisible = false;
    _planOverlayExpanded = false;
    _planOverlayUserDismissed = true;
    notifyListeners();
  }

  void togglePlanOverlay() {
    if (_planOverlayVisible) {
      dismissPlanOverlay();
    } else {
      openPlanOverlay();
    }
  }

  void expandPlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayExpanded = true;
    _planOverlayUserDismissed = false;
    notifyListeners();
  }

  void collapsePlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayExpanded = false;
    notifyListeners();
  }

  void togglePlanOverlayExpanded() {
    if (_planOverlayVisible) {
      _planOverlayExpanded = !_planOverlayExpanded;
    } else {
      openPlanOverlay();
    }
    notifyListeners();
  }

  Future<void> navigateFilesInto(String name) async {
    _filesPath = [..._filesPath, name];
    _filesOffset = 0;
    _filesHasMore = true;
    notifyListeners();
    await reloadFiles();
  }

  Future<void> navigateFilesTo(List<String> path) async {
    _filesPath = path;
    _filesOffset = 0;
    _filesHasMore = true;
    notifyListeners();
    await reloadFiles();
  }

  Future<void> reloadFiles() async {
    _filesOffset = 0;
    _filesHasMore = true;
    final path = _filesPath.join('/');
    try {
      final chunk = await api.listFiles(
        path: path.isEmpty ? null : path,
        projectId: _activeProjectId,
        limit: _fileChunkSize,
        offset: _filesOffset,
      );
      _filesEntries = chunk;
      _filesOffset = chunk.length;
      _filesHasMore = chunk.length == _fileChunkSize;
      _filesError = '';
    } catch (e) {
      _filesError = '$e';
      _filesHasMore = false;
    }
    notifyListeners();
  }

  Future<void> loadMoreFiles() async {
    if (!_filesHasMore || _loadingMoreFiles) return;
    _loadingMoreFiles = true;
    notifyListeners();
    try {
      final path = _filesPath.join('/');
      final chunk = await api.listFiles(
        path: path.isEmpty ? null : path,
        projectId: _activeProjectId,
        limit: _fileChunkSize,
        offset: _filesOffset,
      );
      final existing = <String>{for (final e in _filesEntries) e.name};
      final fresh = chunk.where((e) => !existing.contains(e.name)).toList();
      _filesEntries = [..._filesEntries, ...fresh];
      _filesOffset += fresh.length;
      _filesHasMore = chunk.length == _fileChunkSize;
    } catch (e) {
      _filesError = '$e';
      _filesHasMore = false;
    }
    _loadingMoreFiles = false;
    notifyListeners();
  }

  @visibleForTesting
  void setFilesEntries(List<DirEntry> entries) {
    _filesEntries = entries;
    _filesError = '';
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
    await _loadNotificationPrefs();
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

  void startHealthChecks() {
    _healthTimer?.cancel();
    checkConnection();
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      checkConnection();
    });
  }

  void stopHealthChecks() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  void startGitRefresh() {
    _gitRefreshTimer?.cancel();
    _gitRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshGitState();
    });
  }

  void stopGitRefresh() {
    _gitRefreshTimer?.cancel();
    _gitRefreshTimer = null;
  }

  /// Refresh git state for the active project and, when the git dialog is open,
  /// the dialog's project. This keeps the sidebar and dialog in sync when an
  /// external process (e.g. an AI agent) changes the current branch.
  Future<void> _refreshGitState() async {
    if (_refreshingGit) return;
    _refreshingGit = true;
    try {
      final projectId = _activeProjectId;
      final dialogProjectId = _gitDialogProjectId;
      if (projectId != null) {
        await _refreshGitForProject(projectId);
      }
      if (dialogProjectId != null && dialogProjectId != projectId) {
        await _refreshGitForProject(dialogProjectId);
      }
      await loadProjects();
    } finally {
      _refreshingGit = false;
    }
  }

  Future<void> _refreshGitForProject(int projectId) async {
    try {
      final info = await api.gitRepoStatus(projectId, force: true);
      _gitRepoInfo[projectId] = info;
      _syncProjectBranch(projectId, info);
      _globalError = '';
      if (_dialog == DialogKind.gitBranches &&
          _gitDialogProjectId == projectId) {
        await _loadGitBranchesAndWorktrees(projectId);
      }
    } catch (e) {
      _gitRepoInfo.remove(projectId);
    }
    notifyListeners();
  }

  Future<void> checkConnection() async {
    final ok = await api.checkHealth();
    final next = ok
        ? ConnectionStatus.connected
        : ConnectionStatus.disconnected;
    if (_connectionStatus != next) {
      _connectionStatus = next;
      notifyListeners();
    }
  }

  Future<void> loadProjects() async {
    _projectsOffset = 0;
    _projectsHasMore = true;
    try {
      final chunk = await api.listProjects(limit: _projectChunkSize, offset: 0);
      _projects = chunk;
      _projectsOffset = chunk.length;
      _projectsHasMore = chunk.length == _projectChunkSize;
    } catch (_) {
      _projects = [];
      _projectsOffset = 0;
      _projectsHasMore = false;
    }
  }

  Future<void> loadMoreProjects() async {
    if (!_projectsHasMore || _loadingMoreProjects) return;
    _loadingMoreProjects = true;
    notifyListeners();
    try {
      final chunk = await api.listProjects(
        limit: _projectChunkSize,
        offset: _projectsOffset,
      );
      final existing = <int>{for (final p in _projects) p.id};
      final fresh = chunk.where((p) => !existing.contains(p.id)).toList();
      _projects = [..._projects, ...fresh];
      _projectsOffset += fresh.length;
      _projectsHasMore = chunk.length == _projectChunkSize;
    } finally {
      _loadingMoreProjects = false;
      notifyListeners();
    }
  }

  /// Load the next chunk of user threads. When [reset] is true, replace
  /// existing threads and reset the offset.
  Future<void> _loadUserThreadsChunk({bool reset = false}) async {
    if (reset) {
      _userThreadsOffset = 0;
      _userThreadsHasMore = true;
    }
    if (!_userThreadsHasMore || _loadingMoreUserThreads) return;
    _loadingMoreUserThreads = true;
    try {
      final chunk = await api.listThreads(
        limit: _threadChunkSize,
        offset: _userThreadsOffset,
      );
      if (reset) {
        _threads = chunk;
      } else {
        _mergeThreads(chunk);
      }
      _userThreadsOffset += chunk.length;
      _userThreadsHasMore = chunk.length == _threadChunkSize;
    } catch (_) {}
    _loadingMoreUserThreads = false;
  }

  /// Load the next chunk of threads for a specific project.
  Future<void> _loadProjectThreadsChunk(
    int projectId, {
    bool reset = false,
  }) async {
    if (reset) {
      _projectThreadOffsets[projectId] = 0;
      _projectThreadsHasMore[projectId] = true;
    }
    final offset = _projectThreadOffsets[projectId] ?? 0;
    final hasMore = _projectThreadsHasMore[projectId] ?? true;
    if (!hasMore || (_loadingMoreProjectThreads[projectId] ?? false)) return;
    _loadingMoreProjectThreads[projectId] = true;
    try {
      final chunk = await api.listThreadsForProject(
        projectId,
        limit: _threadChunkSize,
        offset: offset,
      );
      _mergeThreads(chunk);
      _projectThreadOffsets[projectId] = offset + chunk.length;
      _projectThreadsHasMore[projectId] = chunk.length == _threadChunkSize;
    } catch (_) {}
    _loadingMoreProjectThreads[projectId] = false;
  }

  void _mergeThreads(List<Thread> incoming) {
    final existing = <String>{for (final t in _threads) t.id};
    final fresh = incoming.where((t) => !existing.contains(t.id)).toList();
    if (fresh.isNotEmpty) {
      _threads = [..._threads, ...fresh];
    }
  }

  Future<void> refreshThreadsAndGroups() async {
    await Future.wait([
      _loadUserThreadsChunk(reset: true),
      (() async {
        try {
          _groups = await api.listThreadGroups();
        } catch (_) {}
      })(),
    ]);
    notifyListeners();
    unawaited(refreshRunningThreads());
  }

  Future<void> loadMoreThreads() async {
    await _loadUserThreadsChunk();
    notifyListeners();
  }

  Future<void> loadMoreProjectThreads(int projectId) async {
    await _loadProjectThreadsChunk(projectId);
    notifyListeners();
  }

  Future<void> refreshRunningThreads() async {
    if (_threads.isEmpty) {
      _runningThreadIds.clear();
      notifyListeners();
      return;
    }

    try {
      final running = await api.getThreadRuns();
      final loaded = <String>{for (final t in _threads) t.id};
      _runningThreadIds
        ..clear()
        ..addAll(running.where((id) => loaded.contains(id)));
    } catch (_) {
      _runningThreadIds.clear();
    }
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
      startHealthChecks();
      startGitRefresh();
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
      loadCloneRoot(),
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

  // ---- Projects ----

  Future<void> selectProject(int id) async {
    if (_activeThreadId == null) {
      _activeProjectId = id;
    }
    _page = MainPage.threads;
    _globalError = '';
    notifyListeners();
    await refreshThreadsAndGroups();
    await _loadProjectThreadsChunk(id, reset: true);
    notifyListeners();
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
    _projects = ids
        .asMap()
        .entries
        .map((e) => map[e.value]!.copyWith(position: e.key))
        .toList();
    _projects.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byPosition = a.position.compareTo(b.position);
      if (byPosition != 0) return byPosition;
      return a.id.compareTo(b.id);
    });
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

  Future<void> openRenameProjectDialog(int id, String name) async {
    _renameProjectId = id;
    _renameThreadId = null;
    _renameInitialName = name;
    _dialog = DialogKind.renameProject;
    _userMenuOpen = false;
    notifyListeners();
  }

  Future<void> openRenameThreadDialog(String id, String title) async {
    _renameProjectId = null;
    _renameThreadId = id;
    _renameInitialName = title;
    _dialog = DialogKind.renameThread;
    _userMenuOpen = false;
    notifyListeners();
  }

  Future<void> renameProject(int id, String name) async {
    _globalError = '';
    notifyListeners();
    try {
      final updated = await api.renameProject(id, name);
      final index = _projects.indexWhere((p) => p.id == id);
      if (index >= 0) {
        _projects = [
          ..._projects.sublist(0, index),
          updated,
          ..._projects.sublist(index + 1),
        ];
      }
      _dialog = DialogKind.none;
      _renameProjectId = null;
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> pinProject(int id, bool pinned) async {
    _globalError = '';
    notifyListeners();
    try {
      final updated = await api.pinProject(id, pinned);
      final index = _projects.indexWhere((p) => p.id == id);
      if (index >= 0) {
        _projects = [..._projects];
        _projects[index] = updated;
        _projects.sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          final byPosition = a.position.compareTo(b.position);
          if (byPosition != 0) return byPosition;
          return a.id.compareTo(b.id);
        });
      }
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> renameThread(String id, String title) async {
    _globalError = '';
    notifyListeners();
    try {
      await api.renameThread(id, title);
      final index = _threads.indexWhere((t) => t.id == id);
      if (index >= 0) {
        _threads = [
          ..._threads.sublist(0, index),
          _threads[index].copyWith(title: title),
          ..._threads.sublist(index + 1),
        ];
      }
      if (_activeThreadId == id) {
        await _activeStore?.reloadDetail();
      }
      _dialog = DialogKind.none;
      _renameThreadId = null;
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> pinThread(String id, bool pinned) async {
    _globalError = '';
    notifyListeners();
    try {
      final updated = await api.pinThread(id, pinned);
      final index = _threads.indexWhere((t) => t.id == id);
      if (index >= 0) {
        _threads = [..._threads];
        _threads[index] = updated;
        _threads.sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          final byUpdated = b.updatedAt.compareTo(a.updatedAt);
          if (byUpdated != 0) return byUpdated;
          return a.id.compareTo(b.id);
        });
      }
      if (_activeThreadId == id) {
        await _activeStore?.reloadDetail();
      }
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
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
    _threadOpening = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.getThread(id, includeMessages: false),
        api.getThreadProject(id),
      ]);
      final detail = results[0] as ThreadDetail;
      _mergeThreads([detail.thread]);
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
      _threadOpening = false;
      previous?.dispose();

      // If the backend is already running this thread, reconnect to it.
      await store.resume();
      unawaited(refreshLinkedMergeRequest());
    } catch (e) {
      _threadOpening = false;
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

  Future<void> respondToAskRequest(Map<String, dynamic>? answers) async {
    final store = _activeStore;
    if (store == null) return;
    try {
      await store.respondToAskRequest(answers);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  // ---- Git ----

  Future<void> loadGitRepoInfo(int projectId, {bool force = false}) async {
    try {
      final info = await api.gitRepoStatus(projectId, force: force);
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

  Future<void> loadGitBranches(
    int projectId, {
    String? query,
    bool force = false,
  }) async {
    try {
      final branches = await api.gitBranches(
        projectId,
        query: query,
        force: force,
      );
      _gitBranches[projectId] = branches;
      _globalError = '';
    } catch (e) {
      _gitBranches.remove(projectId);
    }
    notifyListeners();
  }

  Future<void> loadGitWorktrees(int projectId, {bool force = false}) async {
    try {
      final worktrees = await api.gitWorktrees(projectId, force: force);
      _gitWorktrees[projectId] = worktrees;
      _globalError = '';
    } catch (e) {
      _gitWorktrees.remove(projectId);
    }
    notifyListeners();
  }

  Future<void> openGitBranchDialog(int projectId) {
    _gitDialogProjectId = projectId;
    _dialog = DialogKind.gitBranches;
    _userMenuOpen = false;
    notifyListeners();
    // Load repo, branches and worktrees in the background so the panel opens
    // instantly and content streams in as it becomes ready.
    return _loadGitData(projectId);
  }

  Future<void> _loadGitData(int projectId) async {
    await Future.wait([
      loadGitRepoInfo(projectId, force: true),
      loadGitBranches(projectId, force: true),
      loadGitWorktrees(projectId, force: true),
    ]);
  }

  Future<void> _loadGitBranchesAndWorktrees(int projectId) async {
    await Future.wait([
      loadGitBranches(projectId, force: true),
      loadGitWorktrees(projectId, force: true),
    ]);
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
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      if (switchBranch) unawaited(refreshLinkedMergeRequest());
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
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPull(int projectId) async {
    try {
      await api.gitPull(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPullBranch(int projectId, String name) async {
    try {
      await api.gitPullBranch(projectId, name);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitPush(int projectId) async {
    try {
      await api.gitPush(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
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
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitDeleteWorktree(int projectId, String worktreePath) async {
    try {
      await api.gitDeleteWorktree(projectId, worktreePath);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
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
        unawaited(refreshLinkedMergeRequest());
      }
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  /// The branch used to look up a linked merge request for the active thread:
  /// the thread's pinned branch when set, otherwise the repo's current branch.
  String? get _linkedMrEffectiveBranch {
    final thread = activeThreadDetail?.thread;
    final branch = thread?.branch;
    if (branch != null && branch.isNotEmpty) return branch;
    final projectId = _activeProjectId;
    if (projectId == null) return null;
    final repo = _gitRepoInfo[projectId];
    return repo?.branch.isNotEmpty == true ? repo!.branch : null;
  }

  /// Refresh the linked merge request for the active thread's branch. Safe to
  /// call when no thread or branch is active; it clears the cached MR instead.
  Future<void> refreshLinkedMergeRequest() async {
    final projectId = _activeProjectId;
    final branch = _linkedMrEffectiveBranch;
    if (projectId == null || branch == null || branch.isEmpty) {
      _clearLinkedMergeRequest();
      notifyListeners();
      return;
    }
    await loadLinkedMergeRequest(projectId, branch);
  }

  Future<void> loadLinkedMergeRequest(int projectId, String branch) async {
    _loadingLinkedMergeRequest = true;
    _linkedMrProjectId = projectId;
    _linkedMrBranch = branch;
    notifyListeners();
    try {
      final mr = await api.findMergeRequestForBranch(projectId, branch);
      // Ignore the response if the active thread/branch changed while loading.
      if (_linkedMrProjectId == projectId && _linkedMrBranch == branch) {
        _linkedMergeRequest = mr;
        _loadingLinkedMergeRequest = false;
        notifyListeners();
      }
    } catch (e) {
      if (_linkedMrProjectId == projectId && _linkedMrBranch == branch) {
        _linkedMergeRequest = null;
        _loadingLinkedMergeRequest = false;
        notifyListeners();
      }
    }
  }

  // ---- Clone root ----

  Future<void> loadCloneRoot() async {
    _loadingCloneRoot = true;
    notifyListeners();
    try {
      _cloneRoot = await api.getCloneRoot();
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    } finally {
      _loadingCloneRoot = false;
      notifyListeners();
    }
  }

  Future<void> setCloneRoot(String? path) async {
    _loadingCloneRoot = true;
    notifyListeners();
    try {
      _cloneRoot = await api.setCloneRoot(path?.trim());
      _globalError = '';
    } catch (e) {
      _globalError = '$e';
    } finally {
      _loadingCloneRoot = false;
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

  Future<void> connectGitLab({String? hostname}) async {
    try {
      final updated = await api.connectGitLab(hostname: hostname);
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
    _mergeRequestUrl = null;
    _issueUrl = null;
    _renameProjectId = null;
    _renameThreadId = null;
    _renameInitialName = '';
    notifyListeners();
  }

  /// Open the merge request or issue panel if [url] is a supported GitLab
  /// URL, otherwise open it in the user's browser.
  Future<void> openLink(String url) async {
    if (GitLabMergeRequestProvider.canHandleUrl(url)) {
      _mergeRequestUrl = url;
      _dialog = DialogKind.mergeRequest;
      _userMenuOpen = false;
      notifyListeners();
      return;
    }
    if (GitLabIssueProvider.canHandleUrl(url)) {
      _issueUrl = url;
      _dialog = DialogKind.issue;
      _userMenuOpen = false;
      notifyListeners();
      return;
    }
    await link_opener.openLink(url);
  }
}
