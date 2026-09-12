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

  // Inline diff preview state. Keys are `'s:<path>'` / `'u:<path>'` so a
  // file's staged and unstaged previews are tracked independently.
  @override
  final Map<String, FileDiff?> _gitDiffs = {};
  @override
  final Set<String> _gitDiffsLoading = {};
  @override
  final Set<String> _gitDiffsExpanded = {};
  @override
  int _gitDiffsSeq = 0;

  // Commit history section state.
  @override
  List<GitCommit> _gitHistory = [];
  @override
  int _gitHistoryOffset = 0;
  @override
  bool _gitHistoryOpen = false;
  @override
  bool _gitHistoryLoading = false;
  @override
  bool _gitHistoryHasMore = false;
  @override
  bool _gitHistoryLoaded = false;
  @override
  int _gitHistorySeq = 0;
  @override
  String _gitHistoryError = '';

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

  /// Bumped whenever any diff-preview or history field changes; the panel's
  /// selector listens on it because the underlying maps mutate in place.
  @override
  int get gitDiffsSeq => _gitDiffsSeq;

  @override
  FileDiff? gitDiffFor(String key) => _gitDiffs[key];
  @override
  bool gitDiffExpanded(String key) => _gitDiffsExpanded.contains(key);
  @override
  bool gitDiffLoading(String key) => _gitDiffsLoading.contains(key);

  @override
  List<GitCommit> get gitHistory => _gitHistory;
  @override
  bool get gitHistoryOpen => _gitHistoryOpen;
  @override
  bool get gitHistoryLoading => _gitHistoryLoading;
  @override
  bool get gitHistoryHasMore => _gitHistoryHasMore;
  @override
  String get gitHistoryError => _gitHistoryError;

  static String gitDiffKey(bool staged, String path) =>
      '${staged ? 's' : 'u'}:$path';

  /// The thread_id to attach to git panel calls. Captured when the data was
  /// loaded so mutations stay pinned to the scope the panel displays even if
  /// the active thread changes before the next refresh.
  @override
  String? get gitApiThreadId => _gitPanelThreadId;

  /// The project the panel data was loaded under; mutations and file opens
  /// must use it rather than the active project, which can move on.
  @override
  int? get gitPanelProjectId => _gitPanelProjectId;

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
      _clearGitDiffs();
      _clearGitHistory();
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
      _clearGitDiffs();
      _clearGitHistory();
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
      _refreshExpandedDiffs();
      // The scope just changed under an open history section; fill it
      // again. A persistent error does not retry on every refresh tick —
      // reopening the section or a mutation does.
      if (_gitHistoryOpen &&
          !_gitHistoryLoaded &&
          !_gitHistoryLoading &&
          _gitHistoryError.isEmpty) {
        unawaited(_loadGitHistory());
      }
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
    final projectId = _gitPanelProjectId ?? _activeProjectId;
    if (projectId != null) {
      unawaited(loadGitRepoInfo(projectId, force: true));
    }
    // A commit/discard/pull changes what history shows, so a closed
    // section must not keep serving the pre-mutation list on reopen.
    invalidateGitHistory();
  }

  /// Drop the loaded history so the next open refetches. Bumping the seq
  /// orphans any in-flight page; `_gitHistoryLoading` is cleared here
  /// because that request will not clear it in its finally.
  @override
  void invalidateGitHistory() {
    _gitHistoryLoaded = false;
    _gitHistorySeq++;
    _gitHistoryLoading = false;
    if (_gitHistoryOpen) unawaited(_loadGitHistory());
  }

  // ---- Inline diff previews ----

  /// Expand a change row's inline diff, fetching it on first open; collapse
  /// it when already expanded.
  @override
  Future<void> toggleGitDiff(GitChangeEntry entry, {required bool staged}) {
    final key = gitDiffKey(staged, entry.path);
    if (!_gitDiffsExpanded.add(key)) {
      _gitDiffsExpanded.remove(key);
      _gitDiffsSeq++;
      notifyListeners();
      return Future.value();
    }
    _gitDiffsSeq++;
    notifyListeners();
    return _loadGitDiff(entry, staged, key);
  }

  Future<void> _loadGitDiff(
    GitChangeEntry entry,
    bool staged,
    String key,
  ) async {
    final projectId = _gitPanelProjectId;
    if (projectId == null) {
      _gitDiffsExpanded.remove(key);
      _gitDiffsSeq++;
      notifyListeners();
      return;
    }
    if (!_gitDiffsLoading.add(key)) return;
    final scopeKey = _gitPanelScopeKey;
    _gitDiffsSeq++;
    notifyListeners();
    try {
      final diff = await api.gitDiff(
        projectId,
        entry.path,
        staged: staged,
        origPath: entry.origPath,
        threadId: gitApiThreadId,
      );
      // A collapse or scope move while loading makes the result stale.
      if (!_gitDiffsExpanded.contains(key) || _gitPanelScopeKey != scopeKey) {
        return;
      }
      _gitDiffs[key] = diff;
    } catch (_) {
      // A preview that fails to load shows the placeholder, not an error.
      // The scope check matches the success path: a failure belonging to
      // an old scope must not blank a freshly expanded row's map entry.
      if (_gitDiffsExpanded.contains(key) && _gitPanelScopeKey == scopeKey) {
        _gitDiffs[key] = null;
      }
    } finally {
      _gitDiffsLoading.remove(key);
      _gitDiffsSeq++;
      notifyListeners();
    }
  }

  void _clearGitDiffs() {
    if (_gitDiffs.isEmpty &&
        _gitDiffsExpanded.isEmpty &&
        _gitDiffsLoading.isEmpty) {
      return;
    }
    _gitDiffs.clear();
    _gitDiffsExpanded.clear();
    _gitDiffsLoading.clear();
    _gitDiffsSeq++;
  }

  /// After each change-list refresh, drop previews whose file left the list
  /// (committed, discarded) and re-fetch the ones still expanded so the
  /// preview tracks the file like an open diff editor would.
  void _refreshExpandedDiffs() {
    final changes = _gitPanelChanges;
    if (changes == null) return;
    final valid = <String>{
      for (final e in changes.staged) gitDiffKey(true, e.path),
      for (final e in changes.unstaged) gitDiffKey(false, e.path),
    };
    final stale = _gitDiffsExpanded.where((k) => !valid.contains(k)).toList();
    if (stale.isNotEmpty) {
      for (final k in stale) {
        _gitDiffsExpanded.remove(k);
        _gitDiffs.remove(k);
        _gitDiffsLoading.remove(k);
      }
      _gitDiffsSeq++;
      notifyListeners();
    }
    for (final e in changes.staged) {
      final k = gitDiffKey(true, e.path);
      if (_gitDiffsExpanded.contains(k)) unawaited(_loadGitDiff(e, true, k));
    }
    for (final e in changes.unstaged) {
      final k = gitDiffKey(false, e.path);
      if (_gitDiffsExpanded.contains(k)) unawaited(_loadGitDiff(e, false, k));
    }
  }

  // ---- Discard ----

  /// Discard the changes for each repo-relative path (for a rename, the
  /// caller passes both the new path and the orig path). [staged] must
  /// match the section the rows came from: staged entries reset to HEAD,
  /// unstaged ones restore the worktree from the index. Irreversible.
  @override
  Future<bool> gitDiscardPaths(List<String> paths, {required bool staged}) =>
      _runGitAction(
        (pid, tid) =>
            api.gitDiscard(pid, paths: paths, staged: staged, threadId: tid),
      );

  // ---- History ----

  /// Open or close the history section; the first open loads the first
  /// page. Reopening also retries after a failed load.
  @override
  Future<void> toggleGitHistory() async {
    _gitHistoryOpen = !_gitHistoryOpen;
    _gitHistoryError = '';
    notifyListeners();
    if (_gitHistoryOpen && !_gitHistoryLoaded && !_gitHistoryLoading) {
      await _loadGitHistory();
    }
  }

  /// Reload the first page of history. `_gitHistorySeq` invalidates any
  /// page load still in flight — including a `loadMore` that a mutation
  /// refresh would otherwise let append onto the new list.
  Future<void> _loadGitHistory() async {
    final projectId = _gitPanelProjectId;
    if (projectId == null || _gitHistoryLoading) return;
    final scopeKey = _gitPanelScopeKey;
    final seq = ++_gitHistorySeq;
    _gitHistoryLoading = true;
    _gitHistoryError = '';
    notifyListeners();
    try {
      final page = await api.gitLog(projectId, threadId: gitApiThreadId);
      if (seq != _gitHistorySeq || _gitPanelScopeKey != scopeKey) return;
      _gitHistory = page.commits;
      _gitHistoryOffset = page.commits.length;
      _gitHistoryHasMore = page.hasMore;
      _gitHistoryLoaded = true;
    } on ApiException catch (e) {
      if (seq != _gitHistorySeq || _gitPanelScopeKey != scopeKey) return;
      // A non-JSON 404 means this backend predates the log endpoint; the
      // section stays empty and counts as loaded so the refresh tick does
      // not keep polling a route that will never appear.
      if (e.statusCode == 404 && e.data == null) {
        _gitHistory = [];
        _gitHistoryHasMore = false;
        _gitHistoryLoaded = true;
      } else {
        _gitHistoryError = '$e';
      }
    } catch (e) {
      if (seq != _gitHistorySeq || _gitPanelScopeKey != scopeKey) return;
      _gitHistoryError = '$e';
    } finally {
      if (seq == _gitHistorySeq) _gitHistoryLoading = false;
      notifyListeners();
    }
  }

  /// Fetch the next page of commits, appending after the current list.
  /// The offset counts fetched commits, not kept ones — a page of all
  /// duplicates still advances it. Entries already shown are dropped by
  /// sha — a commit landing between page loads shifts the offset window
  /// and would otherwise repeat the boundary commit.
  @override
  Future<void> loadMoreGitHistory() async {
    final projectId = _gitPanelProjectId;
    if (projectId == null || _gitHistoryLoading || !_gitHistoryHasMore) {
      return;
    }
    final scopeKey = _gitPanelScopeKey;
    final seq = ++_gitHistorySeq;
    _gitHistoryLoading = true;
    _gitHistoryError = '';
    notifyListeners();
    try {
      final page = await api.gitLog(
        projectId,
        offset: _gitHistoryOffset,
        threadId: gitApiThreadId,
      );
      if (seq != _gitHistorySeq || _gitPanelScopeKey != scopeKey) return;
      final seen = {for (final c in _gitHistory) c.sha};
      _gitHistory = [
        ..._gitHistory,
        ...page.commits.where((c) => !seen.contains(c.sha)),
      ];
      _gitHistoryOffset += page.commits.length;
      _gitHistoryHasMore = page.hasMore;
    } catch (e) {
      if (seq != _gitHistorySeq || _gitPanelScopeKey != scopeKey) return;
      _gitHistoryError = '$e';
    } finally {
      if (seq == _gitHistorySeq) _gitHistoryLoading = false;
      notifyListeners();
    }
  }

  void _clearGitHistory() {
    _gitHistory = [];
    _gitHistoryOffset = 0;
    _gitHistoryLoading = false;
    _gitHistoryHasMore = false;
    _gitHistoryLoaded = false;
    _gitHistoryError = '';
    // Invalidate any in-flight page so it cannot write into the new scope.
    _gitHistorySeq++;
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
