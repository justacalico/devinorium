import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../models/models.dart';

enum AppView { loading, login, setup, app }

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
    String? activeProjectPath,
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
    List<MessagePart> streamingParts = const [],
    bool streamingThinkingActive = false,
  })  : api = api ?? ApiService() {
    _themeMode = themeMode ?? ThemeMode.system;
    _locale = locale ?? const Locale('en');
    _settingsTopicIndex = settingsTopicIndex ?? 0;
    _sending = sending;
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
    _activeProjectPath = activeProjectPath;
    _activeThreadId = activeThreadId;
    _activeThreadDetail = activeThreadDetail;
    _dialog = dialog ?? DialogKind.none;
    _pendingPermissionRequest = pendingPermissionRequest;
    _filesPath = filesPath;
    _globalError = globalError ?? '';
    _streamingParts.clear();
    _streamingParts.addAll(streamingParts);
    _streamingThinkingActive = streamingThinkingActive;
  }

  @override
  void dispose() {
    _sendSubscription?.cancel();
    _sendSubscription = null;
    super.dispose();
  }

  AppView _view = AppView.loading;
  MainPage _page = MainPage.threads;
  User? _user;
  List<Project> _projects = [];
  List<Thread> _threads = [];
  List<ThreadGroup> _groups = [];
  List<ModelInfo> _models = [];
  List<ProviderInfo> _providers = [];
  int? _activeProjectId;
  String? _activeProjectPath;
  String? _activeThreadId;
  ThreadDetail? _activeThreadDetail;
  List<User> _users = [];
  List<Device> _devices = [];
  String _loginError = '';
  String _setupError = '';
  bool _showTotpField = false;
  bool _userMenuOpen = false;
  bool _filesPanelOpen = false;
  List<String> _filesPath = [];
  List<DirEntry> _filesEntries = [];
  String _filesError = '';
  DialogKind _dialog = DialogKind.none;
  String _totpSecret = '';
  String _composerText = '';
  final List<({String filename, String mime, Uint8List bytes})> _attachments =
      [];
  bool _sending = false;
  String _selectedModel = '';
  String _selectedPermission = 'normal';
  final List<MessagePart> _streamingParts = [];
  bool _streamingThinkingActive = false;
  String _globalError = '';
  StreamSubscription? _sendSubscription;
  String? _resumingThreadId;
  PermissionRequest? _pendingPermissionRequest;
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
  List<ThreadGroup> get groups => _groups;
  List<ModelInfo> get models => _models;
  List<ProviderInfo> get providers => _providers;
  int? get activeProjectId => _activeProjectId;
  String? get activeProjectPath => _activeProjectPath;
  Project? get activeProject {
    for (final p in _projects) {
      if (p.id == _activeProjectId) return p;
    }
    return null;
  }

  String? get activeThreadId => _activeThreadId;
  ThreadDetail? get activeThreadDetail => _activeThreadDetail;
  List<User> get users => _users;
  List<Device> get devices => _devices;
  bool get isOwner => _user?.isOwner ?? false;
  String get loginError => _loginError;
  String get setupError => _setupError;
  bool get showTotpField => _showTotpField;
  bool get userMenuOpen => _userMenuOpen;
  bool get filesPanelOpen => _filesPanelOpen;
  List<String> get filesPath => _filesPath;
  List<DirEntry> get filesEntries => _filesEntries;
  String get filesError => _filesError;
  DialogKind get dialog => _dialog;
  String get totpSecret => _totpSecret;
  String get composerText => _composerText;
  bool get sending => _sending;
  List<({String filename, String mime, Uint8List bytes})> get attachments =>
      _attachments;
  String get selectedModel => _selectedModel;
  String get selectedPermission => _selectedPermission;
  List<MessagePart> get streamingParts => _streamingParts;
  bool get streamingThinkingActive => _streamingThinkingActive;
  PermissionRequest? get pendingPermissionRequest => _pendingPermissionRequest;
  String get globalError => _globalError;
  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;
  int get settingsTopicIndex => _settingsTopicIndex;

  GitRepoInfo? gitRepoInfo(int projectId) => _gitRepoInfo[projectId];
  List<GitBranch> gitBranches(int projectId) => _gitBranches[projectId] ?? [];
  List<GitWorktree> gitWorktrees(int projectId) => _gitWorktrees[projectId] ?? [];
  int? get gitDialogProjectId => _gitDialogProjectId;

  List<GitConnection> get gitConnections => _gitConnections;
  bool get loadingGitConnections => _loadingGitConnections;

  // ---- Setters / mutations ----

  void setView(AppView v) { _view = v; notifyListeners(); }
  void setPage(MainPage p) { _page = p; notifyListeners(); }
  void setSettingsTopicIndex(int index) { _settingsTopicIndex = index; notifyListeners(); }
  void toggleUserMenu() { _userMenuOpen = !_userMenuOpen; notifyListeners(); }
  void setUserMenuOpen(bool v) { _userMenuOpen = v; notifyListeners(); }
  void setComposerText(String t) { _composerText = t; notifyListeners(); }
  void addAttachments(
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    _attachments.addAll(files);
    notifyListeners();
  }

  void removeAttachment(int index) {
    _attachments.removeAt(index);
    notifyListeners();
  }

  void clearAttachments() {
    _attachments.clear();
    notifyListeners();
  }

  void setSelectedModel(String m) { _selectedModel = m; notifyListeners(); }
  void setSelectedPermission(String p) { _selectedPermission = p; notifyListeners(); }
  void setLoginError(String e) { _loginError = e; notifyListeners(); }
  void setShowTotpField(bool v) { _showTotpField = v; notifyListeners(); }
  void setGlobalError(String e) { _globalError = e; notifyListeners(); }
  void clearGlobalError() { _globalError = ''; notifyListeners(); }

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

  String? _projectPathById(int id) {
    for (final p in _projects) {
      if (p.id == id) return p.path;
    }
    return null;
  }

  Future<void> openFilesPanel() async {
    _filesPanelOpen = true;
    _filesPath = [];
    _filesError = '';
    notifyListeners();
    await reloadFiles();
  }

  void closeFilesPanel() { _filesPanelOpen = false; notifyListeners(); }

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
    try {
      _models = await api.listModels();
      if (_models.isNotEmpty && _selectedModel.isEmpty) {
        _selectedModel = _models.first.id;
      }
    } catch (_) {}
    try {
      _providers = await api.listProviders();
    } catch (_) {}
  }

  Future<void> bootstrap() async {
    await _loadThemeMode();
    await _loadLanguage();
    setAppL10n(_locale);
    try {
      final configured = await api.client.isConfigured;
      if (!configured) {
        _view = api.client.isNative ? AppView.setup : AppView.login;
        notifyListeners();
        return;
      }
      _user = await api.me();
      _view = AppView.app;
      _setupError = '';
      await _loadModelsAndProviders();
      await loadProjects();
      if (_projects.isNotEmpty) {
        await selectProject(_projects.first.id);
      } else {
        await selectAllProjects();
      }
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        await api.client.clearCredentials();
      }
      _setupError = e is ApiException ? e.message : appL10n.connectionFailed;
      _view = api.client.isNative ? AppView.setup : AppView.login;
      notifyListeners();
    }
  }

  Future<void> completePairing(PairingResponse pairing) async {
    try {
      await api.client.setServerUrl(pairing.serverUrl);
      await api.client.setToken(pairing.token);
      await api.client.setUsername(pairing.username);
      await bootstrap();
    } catch (e) {
      _setupError = e is ApiException ? e.message : appL10n.importFailed;
      _view = AppView.setup;
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
    try {
      _threads = await api.listThreads();
    } catch (_) {}
    try {
      _groups = await api.listThreadGroups();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> doLogin({required String username, required String password, String? totp}) async {
    _loginError = '';
    notifyListeners();
    try {
      final res = await api.login(username: username, password: password, totp: totp);
      if (res.totpRequired) {
        _view = AppView.login;
        _showTotpField = true;
        _loginError = appL10n.totpPrompt;
        notifyListeners();
        return;
      }
      _user = await api.me();
      _view = AppView.app;
      _showTotpField = false;
      _loginError = '';
      await _loadModelsAndProviders();
      await loadProjects();
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

  Future<PairingResponse> createPairing({
    required String serverUrl,
    String? name,
  }) async {
    return api.createPairing(serverUrl: serverUrl, name: name);
  }

  Future<void> createUser({required String username, required String password}) async {
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
    await _sendSubscription?.cancel();
    _sendSubscription = null;
    try { await api.logout(); } catch (_) {}
    try {
      await api.client.clearCredentials();
    } catch (_) {}
    _user = null;
    _users = [];
    _settingsTopicIndex = 0;
    _view = api.client.isNative ? AppView.setup : AppView.login;
    _page = MainPage.threads;
    _userMenuOpen = false;
    _activeThreadId = null;
    _activeThreadDetail = null;
    _projects = [];
    _activeProjectId = null;
    _activeProjectPath = null;
    _showTotpField = false;
    _loginError = '';
    _composerText = '';
    _attachments.clear();
    _streamingParts.clear();
    _streamingThinkingActive = false;
    _sending = false;
    notifyListeners();
  }

  // ---- Projects ----

  Future<void> selectProject(int id) async {
    _activeProjectId = id;
    _activeProjectPath = _projectPathById(id);
    _activeThreadId = null;
    _activeThreadDetail = null;
    _page = MainPage.threads;
    _globalError = '';
    _attachments.clear();
    _composerText = '';
    notifyListeners();
    await refreshThreadsAndGroups();
    unawaited(loadGitRepoInfo(id));
  }

  Future<void> selectAllProjects() async {
    _activeProjectId = null;
    _activeProjectPath = null;
    _activeThreadId = null;
    _activeThreadDetail = null;
    _page = MainPage.threads;
    _globalError = '';
    _attachments.clear();
    _composerText = '';
    notifyListeners();
    await refreshThreadsAndGroups();
  }

  Future<void> createProject({required String name, required String path}) async {
    _globalError = '';
    notifyListeners();
    try {
      final p = await api.createProject(name: name, path: path);
      _projects = [..._projects, p];
      _activeProjectId = p.id;
      _activeProjectPath = p.path;
      _activeThreadId = null;
      _activeThreadDetail = null;
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
        _activeThreadId = null;
        _activeThreadDetail = null;
        if (_projects.isNotEmpty) {
          _activeProjectId = _projects.first.id;
          _activeProjectPath = _projects.first.path;
        } else {
          _activeProjectId = null;
          _activeProjectPath = null;
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
      _activeProjectId = targetId;
      _activeProjectPath = _projectPathById(targetId);
      _activeThreadId = null;
      _activeThreadDetail = null;
      _page = MainPage.threads;
      notifyListeners();
    }
    _page = MainPage.threads;
    notifyListeners();
    try {
      final t = await api.createThread(
        projectId: targetId,
        title: appL10n.newThread,
        model: _selectedModel.isEmpty ? null : _selectedModel,
        permissionMode: _selectedPermission,
      );
      _activeThreadId = t.id;
      try {
        _activeThreadDetail = await api.getThread(t.id);
      } catch (_) {}
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> openThread(String id) async {
    // Cancel any in-flight send and clear transient state before switching.
    await _sendSubscription?.cancel();
    _sendSubscription = null;
    _clearPermissionRequest();
    _sending = false;
    _streamingParts.clear();
    _streamingThinkingActive = false;
    _attachments.clear();
    _composerText = '';
    _resumingThreadId = null;

    _activeThreadId = id;
    notifyListeners();
    try {
      _activeThreadDetail = await api.getThread(id);
      if (_activeThreadDetail != null) {
        _selectedModel = _activeThreadDetail!.thread.model;
        _selectedPermission = _activeThreadDetail!.thread.permissionMode;
      }
      notifyListeners();

      // Discover the thread's project and switch the active project.
      try {
        final info = await api.getThreadProject(id);
        final projectId = (info['project_id'] as num).toInt();
        _activeProjectId = projectId;
        _activeProjectPath = info['path'] as String? ?? _projectPathById(projectId);
      } catch (_) {
        final projectId = _activeThreadDetail?.thread.projectId;
        if (projectId != null && projectId != 0 && projectId != _activeProjectId) {
          _activeProjectId = projectId;
          _activeProjectPath = _projectPathById(projectId);
        }
      }

      // Load the threads list for the active project.
      await refreshThreadsAndGroups();

      // If the backend is already running this thread, reconnect to it.
      await resumeThread(id);
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
    final tid = _activeThreadId;
    if (tid == null) return;
    try {
      await api.updateThreadSettings(
        tid,
        model: _selectedModel,
        permissionMode: _selectedPermission,
      );
      _activeThreadDetail = await api.getThread(tid);
      notifyListeners();
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteThread(String id, {bool skipConfirm = false}) async {
    try {
      await api.deleteThread(id);
      if (_activeThreadId == id) {
        _activeThreadId = null;
        _activeThreadDetail = null;
      }
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> deleteThreadGroup(int id, {bool skipConfirm = false}) async {
    try {
      await api.deleteThreadGroup(id);
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  // ---- Streaming send ----

  void _handleRunEvent(String tid, SseEvent ev) {
    switch (ev.event) {
      case 'user_message':
        clearAttachments();
        _composerText = '';
        final msg = parseSseMessage(ev.data);
        if (msg != null && _activeThreadDetail != null) {
          _activeThreadDetail = _activeThreadDetail!.copyWith(
            messages: [..._activeThreadDetail!.messages, msg],
          );
          notifyListeners();
        }
        break;
      case 'permission_request':
        final decoded = tryDecodeJson(ev.data);
        if (decoded != null) {
          try {
            _pendingPermissionRequest = PermissionRequest.fromJson(decoded);
            _dialog = DialogKind.permissionRequest;
            notifyListeners();
          } catch (e) {
            _globalError = appL10n.invalidPermissionRequest('$e');
            notifyListeners();
          }
        } else {
          _globalError = appL10n.failedToDecodePermissionRequest;
          notifyListeners();
        }
        break;
      case 'part':
        final decoded = tryDecodeJson(ev.data);
        if (decoded != null) {
          try {
            _streamingParts.add(MessagePart.fromJson(decoded));
            _updateStreamingThinkingActive();
            notifyListeners();
          } catch (e) {
            // ignore malformed part
          }
        }
        break;
      case 'part_update':
        final decoded = tryDecodeJson(ev.data);
        if (decoded != null) {
          try {
            final part = MessagePart.fromJson(decoded);
            final idx = _streamingParts.indexWhere((p) => p.id == part.id);
            if (idx >= 0) {
              _streamingParts[idx] = part;
            } else {
              _streamingParts.add(part);
            }
            _updateStreamingThinkingActive();
            notifyListeners();
          } catch (e) {
            // ignore malformed part update
          }
        }
        break;
      case 'done':
        final msg = parseSseMessage(ev.data);
        _streamingParts.clear();
        _streamingThinkingActive = false;
        if (msg != null && _activeThreadDetail != null) {
          _activeThreadDetail = _activeThreadDetail!.copyWith(
            messages: [..._activeThreadDetail!.messages, msg],
          );
        }
        _sending = false;
        _sendSubscription = null;
        notifyListeners();
        refreshThreadsAndGroups();
        break;
      case 'error':
        _clearPermissionRequest();
        _streamingParts.clear();
        _streamingThinkingActive = false;
    
        _sending = false;
        _sendSubscription = null;
        _globalError = ev.data;
        notifyListeners();
        api.getThread(tid).then((d) {
          _activeThreadDetail = d;
          notifyListeners();
        }).catchError((_) {});
        break;
    }
  }

  void _updateStreamingThinkingActive() {
    _streamingThinkingActive = _streamingParts.isNotEmpty &&
        _streamingParts.last.type == 'thinking';
  }

  void _handleRunError(String tid, Object e) {
    _sendSubscription = null;
    _clearPermissionRequest();
    if (e is ApiException && e.statusCode == 409 && _resumingThreadId != tid) {
      _resumingThreadId = tid;
      resumeThread(tid).whenComplete(() {
        if (_resumingThreadId == tid) _resumingThreadId = null;
      });
      return;
    }
    _streamingParts.clear();
    _streamingThinkingActive = false;
    _sending = false;
    _globalError = '$e';
    notifyListeners();
    api.getThread(tid).then((d) {
      _activeThreadDetail = d;
      notifyListeners();
    }).catchError((_) {});
  }

  void _handleRunOnDone(String tid) {
    _sendSubscription = null;
    _clearPermissionRequest();
    if (_sending) {
      _sending = false;
      _streamingParts.clear();
      _streamingThinkingActive = false;
      notifyListeners();
      api.getThread(tid).then((d) {
        _activeThreadDetail = d;
        notifyListeners();
      }).catchError((_) {});
    }
  }

  Future<void> resumeThread(String id) async {
    await _sendSubscription?.cancel();
    _sendSubscription = null;
    _clearPermissionRequest();

    try {
      final run = await api.getThreadRun(id);
      final status = run['status'] as String? ?? 'idle';
      if (status == 'running') {
        _sending = true;
        _streamingParts.clear();
        _streamingThinkingActive = false;
        clearAttachments();
        if (_resumingThreadId != id) _composerText = '';
        notifyListeners();

        late StreamSubscription? sub;
        sub = api.watchThreadEvents(id).listen(
          (ev) {
            if (_sendSubscription != sub) return;
            _handleRunEvent(id, ev);
          },
          onError: (e) {
            if (_sendSubscription != sub) return;
            _handleRunError(id, e);
          },
          onDone: () {
            if (_sendSubscription != sub) return;
            _handleRunOnDone(id);
          },
        );
        _sendSubscription = sub;
      } else {
        _sending = false;
        _activeThreadDetail = await api.getThread(id);
        notifyListeners();
      }
    } catch (e) {
      _sending = false;
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> sendMessage() async {
    final text = _composerText.trim();
    final tid = _activeThreadId;
    if (text.isEmpty || tid == null) return;

    await saveThreadSettings();

    await _sendSubscription?.cancel();
    _sendSubscription = null;
    _clearPermissionRequest();

    _sending = true;
    _streamingParts.clear();
    _streamingThinkingActive = false;
    final attachments = List<({String filename, String mime, Uint8List bytes})>.from(_attachments);
    notifyListeners();

    late StreamSubscription? sub;
    sub = api.sendMessageStream(threadId: tid, prompt: text, attachments: attachments).listen(
      (ev) {
        if (_sendSubscription != sub) return;
        _handleRunEvent(tid, ev);
      },
      onError: (e) {
        if (_sendSubscription != sub) return;
        _handleRunError(tid, e);
      },
      onDone: () {
        if (_sendSubscription != sub) return;
        _handleRunOnDone(tid);
      },
    );
    _sendSubscription = sub;
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
    final tid = _activeThreadId;
    final req = _pendingPermissionRequest;
    if (tid == null || req == null) return;
    try {
      await api.respondPermission(tid, req.requestId, optionId);
      _pendingPermissionRequest = null;
      _dialog = DialogKind.none;
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  void _clearPermissionRequest() {
    if (_pendingPermissionRequest != null) {
      _pendingPermissionRequest = null;
      if (_dialog == DialogKind.permissionRequest) {
        _dialog = DialogKind.none;
      }
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

  Future<void> gitCreateBranch(int projectId, String name, {String? base, bool switchBranch = false}) async {
    try {
      await api.gitCreateBranch(projectId, name, base: base, switchBranch: switchBranch);
      _globalError = '';
      await loadGitBranches(projectId);
      await loadGitRepoInfo(projectId);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> gitCheckout(int projectId, String refName, {bool track = false}) async {
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

  Future<void> gitCreateWorktree(int projectId, String name, String base, {bool newBranch = false}) async {
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

  Future<void> setThreadGit(String threadId, {String? branch, String? worktreePath}) async {
    try {
      await api.updateThreadGit(threadId, branch: branch, worktreePath: worktreePath);
      _globalError = '';
      await refreshThreadsAndGroups();
      if (_activeThreadDetail != null && _activeThreadDetail!.thread.id == threadId) {
        _activeThreadDetail = await api.getThread(threadId);
        notifyListeners();
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

  Future<void> connectGitLab({
    required String token,
    String? hostname,
  }) async {
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
