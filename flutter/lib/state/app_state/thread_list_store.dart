part of 'package:devinorium_frontend/state/app_state.dart';

mixin ThreadListStore on AppStateBase {
  @override
  List<Thread> _threads = [];
  @override
  final Set<String> _runningThreadIds = {};
  static const int _threadChunkSize = 50;
  @override
  int _userThreadsOffset = 0;
  @override
  bool _userThreadsHasMore = true;
  @override
  bool _loadingMoreUserThreads = false;
  @override
  final Map<int, int> _projectThreadOffsets = {};
  @override
  final Map<int, bool> _projectThreadsHasMore = {};
  @override
  final Map<int, bool> _loadingMoreProjectThreads = {};
  @override
  List<ThreadGroup> _groups = [];
  @override
  String? _activeThreadId;
  @override
  bool _threadOpening = false;
  @override
  final Map<String, ThreadStore> _threadStores = {};
  @override
  ThreadStore? _activeStore;
  @override
  List<Thread> get threads => _threads;
  @override
  Set<String> get runningThreadIds => _runningThreadIds;
  @override
  List<ThreadGroup> get groups => _groups;
  @override
  String? get activeThreadId => _activeThreadId;
  @override
  ThreadDetail? get activeThreadDetail => _activeStore?.detail.valueOrNull;
  @override
  bool get activeThreadLoading =>
      _threadOpening || _activeStore?.status == ThreadStoreStatus.loading;
  @override
  bool get sending => _activeStore?.sending ?? false;
  @override
  String? get lastRunStatus => _activeStore?.lastRunStatus;
  @override
  List<MessagePart> get streamingParts =>
      _activeStore?.streamingParts ?? const [];
  @override
  bool get streamingThinkingActive =>
      _activeStore?.streamingThinkingActive ?? false;
  @override
  PermissionRequest? get pendingPermissionRequest =>
      _activeStore?.pendingPermissionRequest;
  @override
  AskRequest? get pendingAskRequest => _activeStore?.pendingAskRequest;
  @override
  String? get startedAt => _activeStore?.startedAt;
  @override
  bool get hasMoreThreads => _userThreadsHasMore;
  @override
  bool get isLoadingMoreThreads => _loadingMoreUserThreads;
  @override
  bool hasMoreProjectThreads(int projectId) =>
      _projectThreadsHasMore[projectId] ?? false;
  @override
  bool isLoadingMoreProjectThreads(int projectId) =>
      _loadingMoreProjectThreads[projectId] ?? false;
  @override
  String? _threadTitle(String id) {
    for (final t in _threads) {
      if (t.id == id) return t.title;
    }
    return null;
  }
  @override
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
  @override
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
  @override
  void _mergeThreads(List<Thread> incoming) {
    final existing = <String>{for (final t in _threads) t.id};
    final fresh = incoming.where((t) => !existing.contains(t.id)).toList();
    if (fresh.isNotEmpty) {
      _threads = [..._threads, ...fresh];
    }
  }
  @override
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
  @override
  Future<void> loadMoreThreads() async {
    await _loadUserThreadsChunk();
    notifyListeners();
  }
  @override
  Future<void> loadMoreProjectThreads(int projectId) async {
    await _loadProjectThreadsChunk(projectId);
    notifyListeners();
  }
  @override
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
  @override
  Future<void> openRenameThreadDialog(String id, String title) async {
    _renameProjectId = null;
    _renameThreadId = id;
    _renameInitialName = title;
    _dialog = DialogKind.renameThread;
    _userMenuOpen = false;
    notifyListeners();
  }
  @override
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
  @override
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
  @override
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
  @override
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
  @override
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
  @override
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
  @override
  Future<void> deleteThreadGroup(int id) async {
    try {
      await api.deleteThreadGroup(id);
      await refreshThreadsAndGroups();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
  @override
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
  @override
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
  @override
  Future<void> sendMessage() async {
    final store = _activeStore;
    if (store == null) return;
    if (store.composerText.trim().isEmpty) return;
    await store.sendMessage();
  }
  @override
  Future<void> stopThread() async {
    final store = _activeStore;
    if (store == null || !store.sending) return;
    await store.stop();
  }
  @override
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
  @override
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
}
