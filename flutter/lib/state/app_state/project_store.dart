part of 'package:devinorium_frontend/state/app_state.dart';

mixin ProjectStore on AppStateBase {
  @override
  List<Project> _projects = [];
  static const int _projectChunkSize = 50;
  @override
  int _projectsOffset = 0;
  @override
  bool _projectsHasMore = true;
  @override
  bool _loadingMoreProjects = false;
  @override
  int? _activeProjectId;
  @override
  List<Project> get projects => _projects;
  @override
  int? get activeProjectId => _activeProjectId;
  @override
  bool get hasMoreProjects => _projectsHasMore;
  @override
  bool get isLoadingMoreProjects => _loadingMoreProjects;
  @override
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
  @override
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
  @override
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
  @override
  Future<void> selectAllProjects() async {
    if (_activeThreadId == null) {
      _activeProjectId = null;
    }
    _page = MainPage.threads;
    _globalError = '';
    notifyListeners();
    await refreshThreadsAndGroups();
  }
  @override
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
  @override
  Future<void> openClonedProjectByPath(String path) async {
    final project = _projects.firstWhere(
      (p) => p.path == path,
      orElse: () => Project(
        id: 0,
        name: '',
        path: '',
        pinned: false,
        createdAt: '',
        updatedAt: '',
      ),
    );
    if (project.id != 0) {
      _activeProjectId = project.id;
      _setActiveStore(null);
      _page = MainPage.threads;
      _dialog = DialogKind.none;
      _globalError = '';
      await refreshThreadsAndGroups();
      notifyListeners();
    } else {
      _globalError = 'Project not found after clone.';
      notifyListeners();
    }
  }
  @override
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
  @override
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
  @override
  Future<void> openNewProjectDialog() async {
    _dialog = DialogKind.newProject;
    _userMenuOpen = false;
    notifyListeners();
  }
  @override
  Future<void> openRenameProjectDialog(int id, String name) async {
    _renameProjectId = id;
    _renameThreadId = null;
    _renameInitialName = name;
    _dialog = DialogKind.renameProject;
    _userMenuOpen = false;
    notifyListeners();
  }
  @override
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
  @override
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
}
