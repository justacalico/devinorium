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
  List<GitConnection> _gitConnections = [];
  @override
  bool _loadingGitConnections = false;
  @override
  String? _cloneRoot;
  @override
  bool _loadingCloneRoot = false;
  @override
  bool _cloningRepo = false;
  @override
  String? _cloneRepoResult;
  @override
  MergeRequestLink? get linkedMergeRequest => _linkedMergeRequest;
  @override
  bool get loadingLinkedMergeRequest => _loadingLinkedMergeRequest;
  @override
  String? get cloneRoot => _cloneRoot;
  @override
  bool get loadingCloneRoot => _loadingCloneRoot;
  @override
  bool get cloningRepo => _cloningRepo;
  @override
  String? get cloneRepoResult => _cloneRepoResult;
  @override
  void _clearLinkedMergeRequest() {
    _linkedMergeRequest = null;
    _loadingLinkedMergeRequest = false;
    _linkedMrProjectId = null;
    _linkedMrBranch = null;
  }
  @override
  GitRepoInfo? gitRepoInfo(int projectId) => _gitRepoInfo[projectId];
  @override
  List<GitBranch> gitBranches(int projectId) => _gitBranches[projectId] ?? [];
  @override
  List<GitWorktree> gitWorktrees(int projectId) =>
      _gitWorktrees[projectId] ?? [];
  @override
  List<GitConnection> get gitConnections => _gitConnections;
  @override
  bool get loadingGitConnections => _loadingGitConnections;
  @override
  void openCloneRepoDialog() {
    _dialog = DialogKind.cloneRepo;
    _cloningRepo = false;
    _cloneRepoResult = null;
    _globalError = '';
    notifyListeners();
  }
  @override
  Future<String?> cloneRepo(String url) async {
    _cloningRepo = true;
    _cloneRepoResult = null;
    _globalError = '';
    notifyListeners();
    try {
      final path = await api.cloneRepo(url);
      _cloneRepoResult = path;
      await loadProjects();
      return path;
    } catch (e) {
      _globalError = '$e';
      _cloneRepoResult = null;
      notifyListeners();
      return null;
    } finally {
      _cloningRepo = false;
      notifyListeners();
    }
  }
  @override
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
  @override
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
      return true;
    } catch (e) {
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
    try {
      await api.gitCheckout(projectId, refName, track: track);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }
  @override
  Future<bool> gitPull(int projectId) async {
    try {
      await api.gitPull(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }
  @override
  Future<bool> gitPullBranch(int projectId, String name) async {
    try {
      await api.gitPullBranch(projectId, name);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return false;
    }
  }
  @override
  Future<bool> gitPush(int projectId) async {
    try {
      await api.gitPush(projectId);
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      unawaited(refreshLinkedMergeRequest());
      return true;
    } catch (e) {
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
    try {
      final worktree = await api.gitCreateWorktree(
        projectId,
        name,
        base,
        newBranch: newBranch,
      );
      _globalError = '';
      await loadGitRepoInfo(projectId, force: true);
      await _loadGitBranchesAndWorktrees(projectId);
      await loadProjects();
      return worktree;
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
      return null;
    }
  }
  @override
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
  @override
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
  @override
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
  @override
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
  @override
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
  @override
  Future<void> disconnectGitLab({String? hostname}) async {
    try {
      await api.disconnectGitLab(hostname: hostname);
      await loadGitConnections();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }
}
