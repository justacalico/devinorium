part of 'package:devinorium_frontend/state/app_state.dart';

mixin GitStore on AppStateBase {
  @override
  final Map<int, GitRepoInfo> _gitRepoInfo = {};
  @override
  final Map<int, List<GitBranch>> _gitBranches = {};
  @override
  final Map<int, List<GitWorktree>> _gitWorktrees = {};
  @override
  MergeRequestLink? _linkedMergeRequest;
  @override
  bool _loadingLinkedMergeRequest = false;
  @override
  int? _linkedMrProjectId;
  @override
  String? _linkedMrBranch;
  @override
  int? _linkedMrIid;
  @override
  List<GitConnection> _gitConnections = [];
  List<GitConnection>? _gitConnectionsView;
  @override
  bool _loadingGitConnections = false;
  @override
  String? _cloneRoot;
  @override
  String? _worktreeRoot;
  @override
  bool _loadingCloneRoot = false;
  @override
  bool _loadingWorktreeRoot = false;
  @override
  bool _cloningRepo = false;
  @override
  String? _cloneRepoResult;
  @override
  int _cloneRepoSeq = 0;
  @override
  MergeRequestLink? get linkedMergeRequest => _linkedMergeRequest;
  @override
  bool get loadingLinkedMergeRequest => _loadingLinkedMergeRequest;
  @override
  String? get cloneRoot => _cloneRoot;
  @override
  String? get worktreeRoot => _worktreeRoot;
  @override
  bool get loadingCloneRoot => _loadingCloneRoot;
  @override
  bool get loadingWorktreeRoot => _loadingWorktreeRoot;
  @override
  bool get cloningRepo => _cloningRepo;
  @override
  String? get cloneRepoResult => _cloneRepoResult;

  @override
  void _bumpGitConnections() {
    _gitConnections = List.of(_gitConnections);
    _gitConnectionsView = null;
  }

  @override
  void _clearLinkedMergeRequest() {
    _linkedMergeRequest = null;
    _loadingLinkedMergeRequest = false;
    _linkedMrProjectId = null;
    _linkedMrBranch = null;
    _linkedMrIid = null;
  }

  @override
  GitRepoInfo? gitRepoInfo(int projectId) => _gitRepoInfo[projectId];
  @override
  List<GitBranch> gitBranches(int projectId) =>
      _gitBranches[projectId] ?? const <GitBranch>[];
  @override
  List<GitWorktree> gitWorktrees(int projectId) =>
      _gitWorktrees[projectId] ?? const <GitWorktree>[];
  @override
  List<GitConnection> get gitConnections {
    _gitConnectionsView ??= List.unmodifiable(_gitConnections);
    return _gitConnectionsView!;
  }

  @override
  bool get loadingGitConnections => _loadingGitConnections;
  @override
  void openCloneRepoDialog() {
    _dialog = DialogKind.cloneRepo;
    _cloneRepoSeq++;
    _cloningRepo = false;
    _cloneRepoResult = null;
    _globalError = '';
    notifyListeners();
  }

  @override
  Future<String?> cloneRepo(String url, {String? nodeId}) async {
    final seq = ++_cloneRepoSeq;
    _cloningRepo = true;
    _cloneRepoResult = null;
    _globalError = '';
    notifyListeners();
    try {
      // The uncategorized sentinel isn't a real group, so clones requested
      // under it land ungrouped, same as under "All".
      final gid = _selectedProjectGroupId == kUncategorizedProjectGroupId
          ? null
          : _selectedProjectGroupId;
      final path = await api.cloneRepo(url, nodeId: nodeId, groupId: gid);
      // The clone already landed on the server, so the project list refresh
      // runs even if the user navigated away mid-request.
      await loadProjects();
      // Backends that predate clone group assignment leave the row
      // ungrouped; patch it here so the project stays visible under an
      // active filter. The check runs against the group captured at call
      // time — the filter may have moved on while the clone was in flight.
      if (seq != _cloneRepoSeq) return null;
      if (gid != null) {
        var match = _projects.where((p) => p.path == path).firstOrNull;
        if (match == null) {
          // The clone sorts to the end of the list, so it can sit past the
          // first page that loadProjects fetched.
          await _ensureAllProjectsLoaded();
          match = _projects.where((p) => p.path == path).firstOrNull;
        }
        if (match != null && match.groupId != gid) {
          await setProjectGroup(match.id, gid);
        }
      }
      if (seq != _cloneRepoSeq) return null;
      _cloneRepoResult = path;
      return path;
    } catch (e) {
      if (seq != _cloneRepoSeq) return null;
      _globalError = '$e';
      _cloneRepoResult = null;
      notifyListeners();
      return null;
    } finally {
      if (seq == _cloneRepoSeq) {
        _cloningRepo = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> loadGitRepoInfo(int projectId, {bool force = false}) async {
    final gen = _serverSeq;
    try {
      final info = await api.gitRepoStatus(projectId, force: force);
      if (gen != _serverSeq) return;
      _gitRepoInfo[projectId] = info;
      _globalError = '';
      _syncProjectBranch(projectId, info);
    } catch (e) {
      if (gen != _serverSeq) return;
      // 404 / not a repo is not an error; clear the state. Anything else
      // keeps the last known info so the branch toolbar survives a blip.
      if (e is ApiException && e.statusCode == 404) {
        _gitRepoInfo.remove(projectId);
      } else {
        debugLogFailure('git.loadRepoInfo', e);
      }
    }
    notifyListeners();
  }

  @override
  void _syncProjectBranch(int projectId, GitRepoInfo info) {
    final idx = _projects.indexWhere((p) => p.id == projectId);
    if (idx == -1) return;
    _projects = [
      ..._projects.sublist(0, idx),
      _projects[idx].copyWith(isRepo: info.isRepo, gitBranch: info.branch),
      ..._projects.sublist(idx + 1),
    ];
  }

  @override
  Future<void> loadGitBranches(
    int projectId, {
    String? query,
    bool force = false,
  }) async {
    final gen = _serverSeq;
    try {
      final branches = await api.gitBranches(
        projectId,
        query: query,
        force: force,
      );
      if (gen != _serverSeq) return;
      _gitBranches[projectId] = branches;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      if (e is ApiException && e.statusCode == 404) {
        _gitBranches.remove(projectId);
      } else {
        debugLogFailure('git.loadBranches', e);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> loadGitWorktrees(int projectId, {bool force = false}) async {
    final gen = _serverSeq;
    try {
      final worktrees = await api.gitWorktrees(projectId, force: force);
      if (gen != _serverSeq) return;
      _gitWorktrees[projectId] = worktrees;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      if (e is ApiException && e.statusCode == 404) {
        _gitWorktrees.remove(projectId);
      } else {
        debugLogFailure('git.loadWorktrees', e);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> loadGitBranchData(int projectId) async {
    await Future.wait([
      loadGitRepoInfo(projectId, force: true),
      loadGitBranches(projectId, force: true),
      loadGitWorktrees(projectId, force: true),
    ]);
  }

  @override
  Future<void> _loadGitBranchesAndWorktrees(int projectId) async {
    await Future.wait([
      loadGitBranches(projectId, force: true),
      loadGitWorktrees(projectId, force: true),
    ]);
  }

  @override
  Future<bool> gitCreateBranch(
    int projectId,
    String name, {
    String? base,
    bool switchBranch = false,
  }) async {
    final gen = _serverSeq;
    try {
      await api.gitCreateBranch(
        projectId,
        name,
        base: base,
        switchBranch: switchBranch,
      );
      if (gen != _serverSeq) return false;
      _globalError = '';
      if (switchBranch) {
        // Switching branches moves HEAD; loaded history is stale.
        invalidateGitHistory();
        unawaited(refreshLinkedMergeRequest());
      }
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> gitCheckout(
    int projectId,
    String refName, {
    bool track = false,
  }) async {
    final gen = _serverSeq;
    try {
      await api.gitCheckout(projectId, refName, track: track);
      if (gen != _serverSeq) return false;
      _globalError = '';
      // A checkout moves HEAD; the panel's loaded history is stale.
      invalidateGitHistory();
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> gitPull(int projectId) async {
    final gen = _serverSeq;
    try {
      await api.gitPull(projectId);
      if (gen != _serverSeq) return false;
      _globalError = '';
      invalidateGitHistory();
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> gitPullBranch(int projectId, String name) async {
    final gen = _serverSeq;
    try {
      await api.gitPullBranch(projectId, name);
      if (gen != _serverSeq) return false;
      _globalError = '';
      // Pulling the current branch moves HEAD.
      invalidateGitHistory();
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> gitPush(int projectId) async {
    final gen = _serverSeq;
    try {
      await api.gitPush(projectId);
      if (gen != _serverSeq) return false;
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<GitWorktree?> gitCreateWorktree(
    int projectId,
    String name,
    String base, {
    bool newBranch = false,
  }) async {
    final gen = _serverSeq;
    try {
      final worktree = await api.gitCreateWorktree(
        projectId,
        name,
        base,
        newBranch: newBranch,
      );
      if (gen != _serverSeq) return null;
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      return worktree;
    } catch (e) {
      if (gen != _serverSeq) return null;
      _globalError = '$e';
      notifyListeners();
      return null;
    }
  }

  @override
  Future<void> gitDeleteWorktree(int projectId, String worktreePath) async {
    final gen = _serverSeq;
    try {
      await api.gitDeleteWorktree(projectId, worktreePath);
      if (gen != _serverSeq) return;
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<List<Thread>?> threadsUsingWorktree(
    int projectId,
    String worktreePath,
  ) async {
    try {
      return await _threadsUsingWorktree(projectId, worktreePath);
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return null;
    }
  }

  @override
  Future<void> deleteWorktree(int projectId, String worktreePath) async {
    final gen = _serverSeq;
    final dependents = await threadsUsingWorktree(projectId, worktreePath);
    if (gen != _serverSeq || dependents == null) return;
    for (final thread in dependents) {
      // The backend stops a running session and waits for it before the
      // thread row is gone, so this also kills an in-flight run.
      if (gen != _serverSeq) return;
      if (!await deleteThread(thread.id)) return;
    }
    // Deleting a thread may already have removed a managed worktree; only
    // call the git endpoint when the path is still registered. The cached
    // list cannot be trusted for the check because a failed load clears it,
    // so refresh directly and let the error surface.
    final List<GitWorktree> current;
    try {
      current = await api.gitWorktrees(projectId, force: true);
      if (gen != _serverSeq) return;
      _gitWorktrees[projectId] = current;
      _gitBranches[projectId] = await api.gitBranches(projectId, force: true);
      notifyListeners();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
      return;
    }
    if (current.any((w) => w.path == worktreePath)) {
      await gitDeleteWorktree(projectId, worktreePath);
    } else {
      await loadGitRepoInfo(projectId, force: true);
      await loadProjects();
    }
  }

  /// Threads of [projectId] that actually run inside [worktreePath]. The
  /// sidebar's thread list is paged, so dependents are fetched from the API
  /// rather than read from [_threads]; missing one would delete the worktree
  /// out from under a thread that still points at it. worktree_path stays on
  /// the row after a thread switches back to local mode, so only threads
  /// still in worktree mode count.
  Future<List<Thread>> _threadsUsingWorktree(
    int projectId,
    String worktreePath,
  ) async {
    bool usesWorktree(Thread t) =>
        t.worktreePath == worktreePath && t.envMode == 'worktree';
    final found = <String, Thread>{};
    final seen = <String>{};
    var offset = 0;
    while (true) {
      final page = await api.listThreadsForProject(
        projectId,
        limit: 200,
        offset: offset,
      );
      var fresh = 0;
      for (final t in page) {
        if (seen.add(t.id)) fresh++;
        if (t.projectId == projectId && usesWorktree(t)) found[t.id] = t;
      }
      // fresh == 0 means the server ignored the offset and is replaying ids.
      if (page.length < 200 || fresh == 0) break;
      offset += page.length;
    }
    for (final t in _threads) {
      if (seen.contains(t.id)) continue;
      if (t.projectId == projectId && usesWorktree(t)) {
        found[t.id] = t;
      }
    }
    return found.values.toList();
  }

  @override
  Future<void> setThreadGit(
    String threadId, {
    String? branch,
    String? worktreePath,
  }) async {
    final gen = _serverSeq;
    try {
      await api.updateThreadGit(
        threadId,
        branch: branch,
        worktreePath: worktreePath,
      );
      if (gen != _serverSeq) return;
      _globalError = '';
      await refreshThreadsAndGroups();
      if (_activeStore?.threadId == threadId) {
        await _activeStore?.reloadDetail();
        unawaited(refreshLinkedMergeRequest());
      }
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> setThreadEnvMode(String threadId, String envMode) async {
    final gen = _serverSeq;
    try {
      await api.updateThreadSettings(threadId, envMode: envMode);
      if (gen != _serverSeq) return;
      _globalError = '';
      await refreshThreadsAndGroups();
      if (_activeStore?.threadId == threadId) {
        await _activeStore?.reloadDetail();
      }
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> setThreadLinkedMr(String threadId, String? url) async {
    final gen = _serverSeq;
    try {
      await api.setThreadLinkedMr(threadId, url);
      if (gen != _serverSeq) return;
      _globalError = '';
      await refreshThreadsAndGroups();
      if (_activeStore?.threadId == threadId) {
        await _activeStore?.reloadDetail();
        await refreshLinkedMergeRequest();
      }
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> unlinkThreadLinkedMr(String threadId) async {
    await setThreadLinkedMr(threadId, null);
  }

  @override
  String? get _linkedMrEffectiveBranch {
    final thread = activeThreadDetail?.thread;
    final branch = thread?.branch;
    if (branch != null && branch.isNotEmpty) return branch;
    final projectId = _activeProjectId;
    if (projectId == null) return null;
    final repo = _gitRepoInfo[projectId];
    return repo?.branch.isNotEmpty == true ? repo!.branch : null;
  }

  @override
  Future<void> refreshLinkedMergeRequest() async {
    final projectId = _activeProjectId;
    final thread = activeThreadDetail?.thread;
    final linkedRef = thread?.linkedMr;
    if (projectId != null && linkedRef != null) {
      await loadLinkedMergeRequestByIid(projectId, linkedRef);
      return;
    }
    final branch = _linkedMrEffectiveBranch;
    if (projectId == null || branch == null || branch.isEmpty) {
      _clearLinkedMergeRequest();
      notifyListeners();
      return;
    }
    await loadLinkedMergeRequest(projectId, branch);
  }

  @override
  Future<void> loadLinkedMergeRequest(int projectId, String branch) async {
    _loadingLinkedMergeRequest = true;
    _linkedMrProjectId = projectId;
    _linkedMrBranch = branch;
    _linkedMrIid = null;
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

  @override
  Future<void> loadLinkedMergeRequestByIid(
    int projectId,
    LinkedMergeRequestRef ref,
  ) async {
    _loadingLinkedMergeRequest = true;
    _linkedMrProjectId = projectId;
    _linkedMrBranch = '';
    _linkedMrIid = ref.iid;
    notifyListeners();
    try {
      final mr = await api.findMergeRequestByIid(projectId, ref.iid);
      if (_linkedMrProjectId == projectId &&
          _linkedMrBranch == '' &&
          _linkedMrIid == ref.iid) {
        _linkedMergeRequest = mr ?? MergeRequestLink.fromRef(ref);
        _loadingLinkedMergeRequest = false;
        notifyListeners();
      }
    } catch (e) {
      if (_linkedMrProjectId == projectId &&
          _linkedMrBranch == '' &&
          _linkedMrIid == ref.iid) {
        _linkedMergeRequest = MergeRequestLink.fromRef(ref);
        _loadingLinkedMergeRequest = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> loadCloneRoot() async {
    _loadingCloneRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.getCloneRoot();
      if (gen != _serverSeq) return;
      _cloneRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingCloneRoot = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> setCloneRoot(String? path) async {
    _loadingCloneRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.setCloneRoot(path?.trim());
      if (gen != _serverSeq) return;
      _cloneRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingCloneRoot = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> loadWorktreeRoot() async {
    _loadingWorktreeRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.getWorktreeRoot();
      if (gen != _serverSeq) return;
      _worktreeRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingWorktreeRoot = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> setWorktreeRoot(String? path) async {
    _loadingWorktreeRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.setWorktreeRoot(path?.trim());
      if (gen != _serverSeq) return;
      _worktreeRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingWorktreeRoot = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> loadGitConnections() async {
    _loadingGitConnections = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final connections = await api.listGitConnections();
      if (gen != _serverSeq) return;
      _gitConnections = connections;
      _bumpGitConnections();
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingGitConnections = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> connectGitLab({String? hostname}) async {
    final gen = _serverSeq;
    try {
      final updated = await api.connectGitLab(hostname: hostname);
      if (gen != _serverSeq) return;
      final index = _gitConnections.indexWhere((c) => c.id == updated.id);
      if (index >= 0) {
        _gitConnections[index] = updated;
      } else {
        _gitConnections.add(updated);
      }
      _bumpGitConnections();
      _globalError = '';
      notifyListeners();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> disconnectGitLab({String? hostname}) async {
    final gen = _serverSeq;
    try {
      await api.disconnectGitLab(hostname: hostname);
      if (gen != _serverSeq) return;
      await loadGitConnections();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> connectGitHub({String? hostname}) async {
    final gen = _serverSeq;
    try {
      final updated = await api.connectGitHub(hostname: hostname);
      if (gen != _serverSeq) return;
      final index = _gitConnections.indexWhere((c) => c.id == updated.id);
      if (index >= 0) {
        _gitConnections[index] = updated;
      } else {
        _gitConnections.add(updated);
      }
      _bumpGitConnections();
      _globalError = '';
      notifyListeners();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> disconnectGitHub({String? hostname}) async {
    final gen = _serverSeq;
    try {
      await api.disconnectGitHub(hostname: hostname);
      if (gen != _serverSeq) return;
      await loadGitConnections();
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }
}
