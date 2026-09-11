part of 'package:devinorium_frontend/state/app_state.dart';

mixin GitPanelStore on AppStateBase {
  @override
  bool _gitPanelOpen = false;
  @override
  GitChanges? _gitPanelChanges;
  @override
  GitRepoInfo? _gitPanelRepoInfo;
  @override
  bool _gitPanelLoading = false;
  @override
  bool _gitActionBusy = false;
  @override
  bool _gitPanelUnsupported = false;
  @override
  String _gitPanelError = '';
  @override
  String? _gitPanelScopeKey;
  @override
  String? _gitPanelThreadId;
  @override
  int? _gitPanelProjectId;
  @override
  int _gitPanelSeq = 0;

  @override
  bool get gitPanelOpen => _gitPanelOpen;
  @override
  GitChanges? get gitPanelChanges => _gitPanelChanges;
  @override
  GitRepoInfo? get gitPanelRepoInfo => _gitPanelRepoInfo;
  @override
  bool get gitPanelLoading => _gitPanelLoading;
  @override
  bool get gitActionBusy => _gitActionBusy;
  @override
  bool get gitPanelUnsupported => _gitPanelUnsupported;
  @override
  String get gitPanelError => _gitPanelError;

  /// The scope the loaded change list was fetched under. Compare with
  /// [activeFilesScopeKey] to know when the panel shows a stale scope.
  @override
  String? get gitPanelScopeKey => _gitPanelScopeKey;

  /// The thread_id to attach to git panel calls. Captured when the data was
  /// loaded so mutations stay pinned to the scope the panel displays even if
  /// the active thread changes before the next refresh.
  @override
  String? get gitApiThreadId => _gitPanelThreadId;

  @override
  Future<void> openGitPanel() async {
    _gitPanelOpen = true;
    _filesPanelOpen = false;
    _gitPanelError = '';
    notifyListeners();
    await _loadGitPanel(force: true);
  }

  @override
  void closeGitPanel() {
    _gitPanelOpen = false;
    notifyListeners();
  }

  @override
  Future<void> reloadGitChanges() => _loadGitPanel(force: true);

  /// Periodic refresh from the git timer. Runs while the panel is open and
  /// re-reads the scope in case the active thread moved into a worktree.
  @override
  Future<void> refreshGitPanel() {
    // An old backend has no git endpoints; polling them every tick just
    // flickers the placeholder. Manual refresh still retries.
    if (_gitPanelUnsupported) return Future.value();
    return _loadGitPanel();
  }

  Future<void> _loadGitPanel({bool force = false}) async {
    final projectId = _activeProjectId;
    final scopeKey = activeFilesScopeKey;
    if (projectId == null || scopeKey == null) {
      // Bump seq so a still-in-flight load for an older scope cannot write
      // its results into this cleared state.
      _gitPanelSeq++;
      _gitPanelScopeKey = null;
      _gitPanelThreadId = null;
      _gitPanelProjectId = null;
      _gitPanelChanges = null;
      _gitPanelRepoInfo = null;
      _gitPanelError = '';
      _gitPanelUnsupported = false;
      _gitPanelLoading = false;
      notifyListeners();
      return;
    }
    // When the scope moved (project switch, thread entered a worktree) the
    // loaded data is for another root; drop it and show the loading state.
    final scopeChanged = _gitPanelScopeKey != scopeKey;
    _gitPanelScopeKey = scopeKey;
    _gitPanelProjectId = projectId;
    _gitPanelThreadId = scopeKey.startsWith('worktree:')
        ? _activeThreadId
        : null;
    if (scopeChanged) {
      _gitPanelChanges = null;
      _gitPanelRepoInfo = null;
      _gitPanelError = '';
    }
    if (force || scopeChanged || _gitPanelChanges == null) {
      _gitPanelLoading = true;
    }
    _gitPanelUnsupported = false;
    notifyListeners();

    final seq = ++_gitPanelSeq;
    final threadId = gitApiThreadId;
    try {
      // Assign the change list before repo info resolves so a failing
      // second request doesn't discard already-fetched data.
      final changes = await api.gitChanges(
        projectId,
        force: force,
        threadId: threadId,
      );
      if (seq != _gitPanelSeq) return;
      _gitPanelChanges = changes;
      final info = await api.gitRepoStatus(
        projectId,
        force: force,
        threadId: threadId,
      );
      if (seq != _gitPanelSeq) return;
      _gitPanelRepoInfo = info;
      _gitPanelError = '';
      _gitPanelUnsupported = false;
    } on ApiException catch (e) {
      if (seq != _gitPanelSeq) return;
      if (e.statusCode == 404 && e.message == 'not a git repository') {
        // The backend confirmed the scope is not a repository.
        _gitPanelChanges = null;
        _gitPanelRepoInfo = null;
        _gitPanelError = '';
      } else if (e.statusCode == 404 && e.data == null) {
        // A non-JSON 404 means the route itself is missing: this backend
        // predates the git endpoints and the panel cannot work against it.
        _gitPanelChanges = null;
        _gitPanelRepoInfo = null;
        _gitPanelError = '';
        _gitPanelUnsupported = true;
      } else {
        _gitPanelError = '$e';
      }
    } catch (e) {
      if (seq != _gitPanelSeq) return;
      _gitPanelError = '$e';
    }
    _gitPanelLoading = false;
    notifyListeners();
  }

  /// Refresh the panel plus the project-level repo info the thread toolbar
  /// reads its ahead/behind badge from.
  Future<void> _afterGitMutation() async {
    await _loadGitPanel(force: true);
    final projectId = _activeProjectId;
    if (projectId != null) {
      unawaited(loadGitRepoInfo(projectId, force: true));
    }
  }

  Future<bool> _runGitAction(Future<void> Function(int, String?) call) async {
    // Pin to the project the displayed data was loaded from; the active
    // project can change between the load and the tap.
    final projectId = _gitPanelProjectId ?? _activeProjectId;
    if (projectId == null || _gitActionBusy) return false;
    _gitActionBusy = true;
    _gitPanelError = '';
    notifyListeners();
    try {
      await call(projectId, gitApiThreadId);
      await _afterGitMutation();
      return true;
    } catch (e) {
      _gitPanelError = '$e';
      return false;
    } finally {
      _gitActionBusy = false;
      notifyListeners();
    }
  }

  @override
  Future<bool> gitStagePaths(List<String> paths) => _runGitAction(
    (pid, tid) => api.gitStage(pid, paths: paths, threadId: tid),
  );

  @override
  Future<bool> gitUnstagePaths(List<String> paths) => _runGitAction(
    (pid, tid) => api.gitUnstage(pid, paths: paths, threadId: tid),
  );

  @override
  Future<bool> gitStageAll() =>
      _runGitAction((pid, tid) => api.gitStage(pid, all: true, threadId: tid));

  @override
  Future<bool> gitUnstageAll() =>
      _runGitAction((pid, tid) => api.gitUnstage(pid, all: true, threadId: tid));

  /// Commit staged changes, or stage everything first when the index is
  /// empty (the same flow "commit all" buttons use).
  @override
  Future<bool> gitCommitChanges(String message) async {
    final msg = message.trim();
    if (msg.isEmpty) return false;
    final all = _gitPanelChanges?.staged.isEmpty ?? false;
    return _runGitAction(
      (pid, tid) => api
          .gitCommit(pid, msg, all: all, threadId: tid)
          .then((_) {}),
    );
  }

  @override
  Future<bool> gitPanelPull() =>
      _runGitAction((pid, tid) => api.gitPull(pid, threadId: tid));

  @override
  Future<bool> gitPanelPush() =>
      _runGitAction((pid, tid) => api.gitPush(pid, threadId: tid));
}
