import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_service.dart';
import '../models/models.dart';

enum AppView { loading, login, register, app }

enum MainPage { threads, settings }

enum DialogKind { none, totpSetup, invites }

/// Central app state. Mirrors the Dioxus `App` component's signals.
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
  List<Thread> _threads = [];
  List<ThreadGroup> _groups = [];
  List<ModelInfo> _models = [];
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
  bool _sending = false;
  String _selectedModel = '';
  String _selectedPermission = 'normal';
  List<Invite> _invites = [];
  String? _streamingText;
  String _globalError = '';
  StreamSubscription? _sendSubscription;

  // Getters
  AppView get view => _view;
  MainPage get page => _page;
  User? get user => _user;
  List<Thread> get threads => _threads;
  List<ThreadGroup> get groups => _groups;
  List<ModelInfo> get models => _models;
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
  String get selectedModel => _selectedModel;
  String get selectedPermission => _selectedPermission;
  List<Invite> get invites => _invites;
  String? get streamingText => _streamingText;
  String get globalError => _globalError;

  // ---- Setters / mutations ----

  void setView(AppView v) { _view = v; notifyListeners(); }
  void setPage(MainPage p) { _page = p; notifyListeners(); }
  void toggleUserMenu() { _userMenuOpen = !_userMenuOpen; notifyListeners(); }
  void setUserMenuOpen(bool v) { _userMenuOpen = v; notifyListeners(); }
  void setComposerText(String t) { _composerText = t; notifyListeners(); }
  void setSelectedModel(String m) { _selectedModel = m; notifyListeners(); }
  void setSelectedPermission(String p) { _selectedPermission = p; notifyListeners(); }
  void setLoginError(String e) { _loginError = e; notifyListeners(); }
  void setRegisterError(String e) { _registerError = e; notifyListeners(); }
  void setShowTotpField(bool v) { _showTotpField = v; notifyListeners(); }
  void setGlobalError(String e) { _globalError = e; notifyListeners(); }
  void clearGlobalError() { _globalError = ''; notifyListeners(); }

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
      _filesEntries = await api.listFiles(path: path.isEmpty ? null : path);
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
      await api.mkdir(full);
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
      await api.deleteFile(full);
      _filesError = '';
      notifyListeners();
      await reloadFiles();
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }

  // ---- Auth ----

  Future<void> bootstrap() async {
    try {
      _user = await api.me();
      _view = AppView.app;
      try {
        _models = await api.listModels();
        if (_models.isNotEmpty && _selectedModel.isEmpty) {
          _selectedModel = _models.first.id;
        }
      } catch (_) {}
      await refreshThreadsAndGroups();
    } catch (_) {
      _view = AppView.login;
    }
    notifyListeners();
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
      try {
        _models = await api.listModels();
        if (_models.isNotEmpty && _selectedModel.isEmpty) {
          _selectedModel = _models.first.id;
        }
      } catch (_) {}
      await refreshThreadsAndGroups();
      notifyListeners();
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
        // Shouldn't happen for a fresh user, but handle gracefully.
        _registerError = 'TOTP required after registration.';
      } else {
        _user = await api.me();
        _view = AppView.app;
        try {
          _models = await api.listModels();
          if (_models.isNotEmpty && _selectedModel.isEmpty) {
            _selectedModel = _models.first.id;
          }
        } catch (_) {}
        await refreshThreadsAndGroups();
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
    _showTotpField = false;
    _loginError = '';
    _composerText = '';
    _streamingText = null;
    _sending = false;
    notifyListeners();
  }

  // ---- Threads ----

  Future<void> createNewThread() async {
    _page = MainPage.threads;
    notifyListeners();
    try {
      final t = await api.createThread(
        title: 'New thread',
        model: _selectedModel.isEmpty ? null : _selectedModel,
        permissionMode: _selectedPermission,
      );
      _threads = [t, ..._threads];
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
    _activeThreadId = id;
    notifyListeners();
    try {
      _activeThreadDetail = await api.getThread(id);
      notifyListeners();
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

    // Cancel any in-flight send before starting a new one.
    await _sendSubscription?.cancel();
    _sendSubscription = null;

    _sending = true;
    _streamingText = '';
    _composerText = '';
    notifyListeners();

    _sendSubscription = api.sendMessageStream(threadId: tid, prompt: text).listen(
      (ev) {
        switch (ev.event) {
          case 'user_message':
            final msg = parseSseMessage(ev.data);
            if (msg != null && _activeThreadDetail != null) {
              _activeThreadDetail = _activeThreadDetail!.copyWith(
                messages: [..._activeThreadDetail!.messages, msg],
              );
              notifyListeners();
            }
            break;
          case 'chunk':
            _streamingText = (_streamingText ?? '') + ev.data;
            notifyListeners();
            break;
          case 'done':
            final msg = parseSseMessage(ev.data);
            _streamingText = null;
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
            _streamingText = null;
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
        _streamingText = null;
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
        _sendSubscription = null;
        if (_sending) {
          // Stream ended without an explicit done/error event.
          _sending = false;
          _streamingText = null;
          notifyListeners();
          // Reload to ensure consistency.
          api.getThread(tid).then((d) {
            _activeThreadDetail = d;
            notifyListeners();
          }).catchError((_) {});
        }
      },
    );
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

  void closeDialog() {
    _dialog = DialogKind.none;
    notifyListeners();
  }
}
