part of 'package:devinorium_frontend/state/app_state.dart';

mixin GitRefreshStore on AppStateBase {
  @override
  Timer? _gitRefreshTimer;
  @override
  bool _refreshingGit = false;
  @override
  void startGitRefresh() {
    _gitRefreshTimer?.cancel();
    _gitRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshGitState();
    });
  }
  @override
  void stopGitRefresh() {
    _gitRefreshTimer?.cancel();
    _gitRefreshTimer = null;
  }
  @override
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
  @override
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
}
