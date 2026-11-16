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
  String? _projectRoot;
  @override
  bool _loadingProjectRoot = false;
  @override
  List<Project> get projects => _projects;
  @override
  int? get activeProjectId => _activeProjectId;
  @override
  String? get projectRoot => _projectRoot;
  @override
  bool get loadingProjectRoot => _loadingProjectRoot;
  @override
  bool get hasMoreProjects => _projectsHasMore;
  @override
  bool get isLoadingMoreProjects => _loadingMoreProjects;
  // Bumped by loadProjects so an in-flight loadMoreProjects cannot merge a
  // stale page into (or advance the offset past) the freshly replaced list.
  @override
  int _projectsListSeq = 0;

  @override
  Future<void> loadProjects() async {
    _projectsOffset = 0;
    _projectsHasMore = true;
    final listSeq = ++_projectsListSeq;
    final gen = _serverSeq;
    try {
      final chunk = await api.listProjects(limit: _projectChunkSize, offset: 0);
      if (listSeq != _projectsListSeq || gen != _serverSeq) return;
      _projects = chunk;
      _projectsOffset = chunk.length;
      _projectsHasMore = chunk.length == _projectChunkSize;
      _clearKeyedError('projects');
    } catch (e) {
      if (gen != _serverSeq) return;
      _checkAuthFailure(e);
      // Keep the last known list on a transient failure rather than
      // emptying the sidebar.
      _setKeyedError('projects', '$e');
    }
    // Older servers have no project-groups endpoint; keep the project list
    // working and leave the filter empty.
    await loadProjectGroups();
    notifyListeners();
  }

  @override
  Future<void> loadMoreProjects() async {
    if (!_projectsHasMore || _loadingMoreProjects) return;
    _loadingMoreProjects = true;
    notifyListeners();
    final listSeq = _projectsListSeq;
    final gen = _serverSeq;
    try {
      final chunk = await api.listProjects(
        limit: _projectChunkSize,
        offset: _projectsOffset,
      );
      if (listSeq != _projectsListSeq || gen != _serverSeq) return;
      final existing = <int>{for (final p in _projects) p.id};
      final fresh = chunk.where((p) => !existing.contains(p.id)).toList();
      _projects = [..._projects, ...fresh];
      // The offset is a server-side position: it must advance past every
      // fetched row, not just the new ones, or a page of duplicates would
      // re-request itself forever.
      _projectsOffset += chunk.length;
      _projectsHasMore = chunk.length == _projectChunkSize;
      _clearKeyedError('projects');
    } catch (e) {
      if (gen != _serverSeq) return;
      _checkAuthFailure(e);
      _setKeyedError('projects', '$e');
    } finally {
      if (gen == _serverSeq) {
        _loadingMoreProjects = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> selectProject(int id) async {
    final willSwitch = _activeThreadId == null && _activeProjectId != id;
    if (willSwitch) {
      if (hasDirtyEditorTabs) {
        _globalError = appL10n.editorUnsavedSwitchProjects;
        notifyListeners();
        return;
      }
      closeAllEditorTabs();
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
    if (_activeThreadId == null && _activeProjectId != null) {
      if (hasDirtyEditorTabs) {
        _globalError = appL10n.editorUnsavedSwitchProjects;
        notifyListeners();
        return;
      }
      closeAllEditorTabs();
      _activeProjectId = null;
    }
    _page = MainPage.threads;
    _globalError = '';
    notifyListeners();
    await refreshThreadsAndGroups();
  }

  @override
  Future<bool> createProject({
    required String name,
    required String path,
    String? nodeId,
  }) => _addProject(
    () => api.createProject(name: name, path: path, nodeId: nodeId),
  );
  @override
  Future<bool> createNewProject(String name, {String? nodeId}) =>
      _addProject(() => api.createNewProject(name: name, nodeId: nodeId));
  Future<bool> _addProject(Future<Project> Function() create) async {
    _globalError = '';
    notifyListeners();
    if (hasDirtyEditorTabs) {
      _globalError = appL10n.editorUnsavedNewProject;
      notifyListeners();
      return false;
    }
    final gen = _serverSeq;
    try {
      final p = await create();
      if (gen != _serverSeq) return false;
      _projects = [..._projects, p];
      // A project created while a group filter is active joins that group,
      // otherwise it would be invisible in the sidebar. The uncategorized
      // sentinel isn't a real group — new projects are ungrouped anyway.
      final gid = _selectedProjectGroupId;
      if (gid != null && gid != kUncategorizedProjectGroupId) {
        await setProjectGroup(p.id, gid);
        if (gen != _serverSeq) return false;
      }
      if (hasDirtyEditorTabs) {
        _globalError = appL10n.editorUnsavedNewProject;
      } else {
        closeAllEditorTabs();
        _activeProjectId = p.id;
        _setActiveStore(null);
      }
      _page = MainPage.threads;
      await refreshThreadsAndGroups();
      return true;
    } catch (e) {
      if (gen != _serverSeq) return false;
      _globalError = '$e';
      notifyListeners();
      return false;
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
      if (hasDirtyEditorTabs) {
        _globalError = appL10n.editorUnsavedSwitchProjects;
        notifyListeners();
        return;
      }
      closeAllEditorTabs();
      _activeProjectId = project.id;
      _setActiveStore(null);
      _page = MainPage.threads;
      _dialog = DialogKind.none;
      _globalError = '';
      await refreshThreadsAndGroups();
      notifyListeners();
    } else {
      _globalError = appL10n.projectNotFoundAfterClone;
      notifyListeners();
    }
  }

  @override
  Future<void> deleteProject(int id) async {
    if (_activeProjectId == id && hasDirtyEditorTabs) {
      _globalError = appL10n.editorUnsavedDeleteProject;
      notifyListeners();
      return;
    }
    final gen = _serverSeq;
    try {
      await api.deleteProject(id);
      if (gen != _serverSeq) return;
      _projects = _projects.where((p) => p.id != id).toList();
      if (_activeProjectId == id) {
        if (hasDirtyEditorTabs) {
          _globalError = appL10n.editorUnsavedDeleteProject;
        } else {
          closeAllEditorTabs();
        }
        _setActiveStore(null);
        if (_projects.isNotEmpty) {
          _activeProjectId = _projects.first.id;
        } else {
          _activeProjectId = null;
        }
      }
      await refreshThreadsAndGroups();
    } catch (e) {
      if (gen != _serverSeq) return;
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

    final gen = _serverSeq;
    try {
      await api.reorderProjects(ids);
    } catch (e) {
      if (gen != _serverSeq) return;
      _projects = oldProjects;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> openNewProjectDialog() async {
    _dialog = DialogKind.newProject;
    _cloneRepoSeq++;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
  }

  @override
  void openCreateProjectDialog() {
    _dialog = DialogKind.createProject;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
    // Loaded lazily so the dialog can show where the folder will land.
    unawaited(loadProjectRoot());
  }

  @override
  Future<void> loadProjectRoot() async {
    _loadingProjectRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.getProjectRoot();
      if (gen != _serverSeq) return;
      _projectRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingProjectRoot = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> setProjectRoot(String? path) async {
    _loadingProjectRoot = true;
    notifyListeners();
    final gen = _serverSeq;
    try {
      final root = await api.setProjectRoot(path?.trim());
      if (gen != _serverSeq) return;
      _projectRoot = root;
      _globalError = '';
    } catch (e) {
      if (gen != _serverSeq) return;
      _globalError = '$e';
    } finally {
      if (gen == _serverSeq) {
        _loadingProjectRoot = false;
        notifyListeners();
      }
    }
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
    final gen = _serverSeq;
    try {
      final updated = await api.renameProject(id, name);
      if (gen != _serverSeq) return;
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
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> pinProject(int id, bool pinned) async {
    _globalError = '';
    notifyListeners();
    final gen = _serverSeq;
    try {
      final updated = await api.pinProject(id, pinned);
      if (gen != _serverSeq) return;
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
      if (gen != _serverSeq) return;
      _globalError = '$e';
      notifyListeners();
    }
  }
}
