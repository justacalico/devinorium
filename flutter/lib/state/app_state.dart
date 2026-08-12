import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_service.dart';
import '../models/models.dart';

enum AppView { loading, login, register, app }

enum MainPage { threads, settings }

enum DialogKind { none, totpSetup, invites, newProject, permissionRequest }

/// Central app state.
class AppState extends ChangeNotifier {
  final ApiService api = ApiService();

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
  String _loginError = '';
  String _registerError = '';
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
  List<Invite> _invites = [];
  String? _streamingText;
  String? _streamingThinking;
  bool _streamingThinkingActive = false;
  final Map<String, ToolCallData> _streamingToolCalls = {};
  String _globalError = '';
  StreamSubscription? _sendSubscription;
  PermissionRequest? _pendingPermissionRequest;

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
  String get loginError => _loginError;
  String get registerError => _registerError;
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
  List<Invite> get invites => _invites;
  String? get streamingText => _streamingText;
  String? get streamingThinking => _streamingThinking;
  bool get streamingThinkingActive => _streamingThinkingActive;
  Map<String, ToolCallData> get streamingToolCalls => _streamingToolCalls;
  PermissionRequest? get pendingPermissionRequest => _pendingPermissionRequest;
  String get globalError => _globalError;

  // ---- Setters / mutations ----

  void setView(AppView v) { _view = v; notifyListeners(); }
  void setPage(MainPage p) { _page = p; notifyListeners(); }
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
  void setRegisterError(String e) { _registerError = e; notifyListeners(); }
  void setShowTotpField(bool v) { _showTotpField = v; notifyListeners(); }
  void setGlobalError(String e) { _globalError = e; notifyListeners(); }
  void clearGlobalError() { _globalError = ''; notifyListeners(); }

  String? _projectPathById(int id) {
    for (final p in _projects) {
      if (p.id == id) return p.path;
    }
    return null;
  }

  void openFilesPanel() {
    _filesPanelOpen = true;
    _filesPath = [];
    _filesError = '';
    notifyListeners();
    reloadFiles();
  }

  void closeFilesPanel() { _filesPanelOpen = false; notifyListeners(); }

  void navigateFilesInto(String name) {
    _filesPath = [..._filesPath, name];
    notifyListeners();
    reloadFiles();
  }

  void navigateFilesTo(List<String> path) {
    _filesPath = path;
    notifyListeners();
    reloadFiles();
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
    try {
      _user = await api.me();
      _view = AppView.app;
      await _loadModelsAndProviders();
      await loadProjects();
      if (_projects.isNotEmpty) {
        await selectProject(_projects.first.id);
      } else {
        await selectAllProjects();
      }
    } catch (_) {
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
        _showTotpField = true;
        _loginError = 'Enter your 6-digit TOTP code.';
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
      _loginError = '$e';
      notifyListeners();
    }
  }

  Future<void> doRegister({required String invite, required String username, required String password}) async {
    _registerError = '';
    notifyListeners();
    try {
      await api.register(invite: invite, username: username, password: password);
      // Auto-login.
      final res = await api.login(username: username, password: password);
      if (res.totpRequired) {
        // Shouldn’t happen for a fresh user, but handle gracefully.
        _registerError = 'TOTP required after registration.';
      } else {
        _user = await api.me();
        _view = AppView.app;
        await _loadModelsAndProviders();
        await loadProjects();
        if (_projects.isNotEmpty) {
          await selectProject(_projects.first.id);
        } else {
          await selectAllProjects();
        }
      }
      notifyListeners();
    } catch (e) {
      _registerError = '$e';
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _sendSubscription?.cancel();
    _sendSubscription = null;
    try { await api.logout(); } catch (_) {}
    _user = null;
    _view = AppView.login;
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
    _streamingText = null;
    _streamingThinking = null;
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

  Future<void> openNewProjectDialog() async {
    _dialog = DialogKind.newProject;
    _userMenuOpen = false;
    notifyListeners();
  }

  // ---- Threads ----

  Future<void> createNewThread({int? projectId}) async {
    final targetId = projectId ?? _activeProjectId;
    if (targetId == null) {
      _globalError = 'Select a project first';
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
        title: 'New thread',
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
    _streamingText = null;
    _streamingThinking = null;
    _streamingThinkingActive = false;
    _streamingToolCalls.clear();
    _attachments.clear();

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
    } catch (e) {
      _globalError = '$e';
    }
    notifyListeners();
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

  Future<void> sendMessage() async {
    final text = _composerText.trim();
    final tid = _activeThreadId;
    if (text.isEmpty || tid == null) return;

    // Persist the current model and permission mode before sending, so the
    // backend uses the latest settings.
    await saveThreadSettings();

    // Cancel any in-flight send before starting a new one.
    await _sendSubscription?.cancel();
    _sendSubscription = null;
    _clearPermissionRequest();

    _sending = true;
    _streamingText = '';
    _streamingThinking = null;
    _streamingThinkingActive = false;
    _streamingToolCalls.clear();
    _composerText = '';
    final attachments = List<({String filename, String mime, Uint8List bytes})>.from(_attachments);
    notifyListeners();

    late StreamSubscription? sub;
    sub = api.sendMessageStream(threadId: tid, prompt: text, attachments: attachments).listen(
      (ev) {
        if (_sendSubscription != sub) return;
        switch (ev.event) {
          case 'user_message':
            clearAttachments();
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
                _globalError = 'Invalid permission request: $e';
                notifyListeners();
              }
            } else {
              _globalError = 'Failed to decode permission request';
              notifyListeners();
            }
            break;
          case 'thinking':
            _streamingThinking = (_streamingThinking ?? '') + ev.data;
            _streamingThinkingActive = true;
            notifyListeners();
            break;
          case 'chunk':
            _streamingText = (_streamingText ?? '') + ev.data;
            _streamingThinkingActive = false;
            notifyListeners();
            break;
          case 'tool_call':
            final decoded = tryDecodeJson(ev.data);
            if (decoded != null) {
              final tc = ToolCallData.fromJson(decoded);
              _streamingToolCalls[tc.id] = tc;
              notifyListeners();
            }
            break;
          case 'done':
            final msg = parseSseMessage(ev.data);
            _streamingText = null;
            _streamingThinking = null;
            _streamingThinkingActive = false;
            if (msg != null && _activeThreadDetail != null) {
              _activeThreadDetail = _activeThreadDetail!.copyWith(
                messages: [..._activeThreadDetail!.messages, msg],
              );
            }
            _sending = false;
            _sendSubscription = null;
            notifyListeners();
            // Refresh thread list in background (title may have changed).
            refreshThreadsAndGroups();
            break;
          case 'error':
            _clearPermissionRequest();
            _streamingText = null;
            _streamingThinking = null;
            _streamingThinkingActive = false;
            _streamingToolCalls.clear();
            _sending = false;
            _sendSubscription = null;
            _globalError = ev.data;
            notifyListeners();
            // Reload thread detail to recover consistent state.
            api.getThread(tid).then((d) {
              _activeThreadDetail = d;
              notifyListeners();
            }).catchError((_) {});
            break;
        }
      },
      onError: (e) {
        if (_sendSubscription != sub) return;
        _clearPermissionRequest();
        _streamingText = null;
        _streamingThinking = null;
        _streamingThinkingActive = false;
        _streamingToolCalls.clear();
        _sending = false;
        _sendSubscription = null;
        _globalError = '$e';
        notifyListeners();
        api.getThread(tid).then((d) {
          _activeThreadDetail = d;
          notifyListeners();
        }).catchError((_) {});
      },
      onDone: () {
        if (_sendSubscription != sub) return;
        _sendSubscription = null;
        _clearPermissionRequest();
        if (_sending) {
          // Stream ended without an explicit done/error event.
          _sending = false;
          _streamingText = null;
          _streamingThinking = null;
          _streamingThinkingActive = false;
          _streamingToolCalls.clear();
          notifyListeners();
          // Reload to ensure consistency.
          api.getThread(tid).then((d) {
            _activeThreadDetail = d;
            notifyListeners();
          }).catchError((_) {});
        }
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

  // ---- Invites ----

  Future<void> openInvites() async {
    try {
      _invites = await api.listInvites();
      _dialog = DialogKind.invites;
      _userMenuOpen = false;
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  Future<void> createInvite() async {
    try {
      await api.createInvite();
      _invites = await api.listInvites();
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

  void closeDialog() {
    _dialog = DialogKind.none;
    notifyListeners();
  }
}
