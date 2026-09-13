part of 'package:devinorium_frontend/state/app_state.dart';

/// Project groups: named buckets that filter the sidebar project list.
/// `null` selection means "All" — every project is shown.
mixin ProjectGroupStore on AppStateBase {
  @override
  List<ProjectGroup> _projectGroups = [];
  @override
  int? _selectedProjectGroupId;
  @override
  int? _groupAssignProjectId;
  @override
  int? _renameProjectGroupId;
  @override
  bool _projectGroupsUnsupported = false;
  @override
  bool _newGroupFromManage = false;
  bool _loadingAllProjects = false;

  @override
  List<ProjectGroup> get projectGroups => _projectGroups;
  @override
  int? get selectedProjectGroupId => _selectedProjectGroupId;
  @override
  int? get groupAssignProjectId => _groupAssignProjectId;
  @override
  int? get renameProjectGroupId => _renameProjectGroupId;
  @override
  bool get projectGroupsUnsupported => _projectGroupsUnsupported;

  @override
  Future<void> loadProjectGroups() async {
    try {
      _projectGroups = await api.listProjectGroups();
      if (_selectedProjectGroupId != null &&
          !_projectGroups.any((g) => g.id == _selectedProjectGroupId)) {
        _selectedProjectGroupId = null;
      }
      _projectGroupsUnsupported = false;
    } on ApiException catch (e) {
      // A non-JSON 404 means the route itself is missing: this backend
      // predates project groups, so hide the UI instead of erroring.
      if (e.statusCode == 404 && e.data == null) {
        _projectGroupsUnsupported = true;
        _projectGroups = [];
        _selectedProjectGroupId = null;
      } else {
        debugLogFailure('projectGroups.load', e);
      }
    } catch (e) {
      debugLogFailure('projectGroups.load', e);
    }
    notifyListeners();
  }

  /// Filtering is client-side, so selecting a group pulls in any project
  /// pages that are not loaded yet.
  Future<void> _ensureAllProjectsLoaded() async {
    if (_loadingAllProjects) return;
    _loadingAllProjects = true;
    try {
      while (_projectsHasMore) {
        final before = _projectsOffset;
        await loadMoreProjects();
        // A scroll-triggered load may already be in flight; stop rather
        // than spin on a no-op call.
        if (_projectsOffset == before) break;
      }
    } catch (_) {
      // Keep whatever pages loaded; the filter just covers those.
    } finally {
      _loadingAllProjects = false;
    }
  }

  @override
  void selectProjectGroup(int? id) {
    if (_selectedProjectGroupId == id) return;
    _selectedProjectGroupId = id;
    notifyListeners();
    if (id != null) {
      unawaited(_ensureAllProjectsLoaded());
    }
  }

  @override
  void openNewProjectGroupDialog({int? projectId, bool fromManage = false}) {
    _groupAssignProjectId = projectId;
    _newGroupFromManage = fromManage;
    _dialog = DialogKind.newProjectGroup;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
  }

  @override
  void openManageProjectGroupsDialog() {
    _dialog = DialogKind.manageProjectGroups;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
    // The dialog shows per-group project counts, which need every page.
    unawaited(_ensureAllProjectsLoaded());
  }

  @override
  void openRenameProjectGroupDialog(int id, String name) {
    _renameProjectGroupId = id;
    _renameProjectId = null;
    _renameThreadId = null;
    _renameInitialName = name;
    _dialog = DialogKind.renameProjectGroup;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
  }

  @override
  Future<void> createProjectGroup(String name) async {
    _globalError = '';
    notifyListeners();
    try {
      final assignId = _groupAssignProjectId;
      final group = await api.createProjectGroup(
        name: name,
        projectIds: assignId == null ? null : [assignId],
      );
      _projectGroups = [..._projectGroups, group];
      if (assignId != null) {
        _replaceProjectGroupId(assignId, group.id);
      }
      _groupAssignProjectId = null;
      _dialog = _newGroupFromManage
          ? DialogKind.manageProjectGroups
          : DialogKind.none;
      _newGroupFromManage = false;
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> renameProjectGroup(int id, String name) async {
    _globalError = '';
    notifyListeners();
    try {
      final trimmed = name.trim();
      await api.renameProjectGroup(id, trimmed);
      final index = _projectGroups.indexWhere((g) => g.id == id);
      if (index >= 0) {
        _projectGroups = [..._projectGroups];
        _projectGroups[index] = _projectGroups[index].copyWith(name: trimmed);
      }
      _renameProjectGroupId = null;
      _dialog = DialogKind.manageProjectGroups;
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> deleteProjectGroup(int id) async {
    _globalError = '';
    notifyListeners();
    try {
      await api.deleteProjectGroup(id);
      _projectGroups = _projectGroups.where((g) => g.id != id).toList();
      if (_selectedProjectGroupId == id) {
        _selectedProjectGroupId = null;
      }
      for (var i = 0; i < _projects.length; i++) {
        if (_projects[i].groupId == id) {
          _projects[i] = _projects[i].copyWith(groupId: null);
        }
      }
      _projects = [..._projects];
      _globalError = '';
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> setProjectGroup(int projectId, int? groupId) async {
    _globalError = '';
    notifyListeners();
    try {
      final updated = await api.setProjectGroup(projectId, groupId);
      final index = _projects.indexWhere((p) => p.id == projectId);
      if (index >= 0) {
        _projects = [..._projects];
        _projects[index] = updated;
      }
      notifyListeners();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    }
  }

  void _replaceProjectGroupId(int projectId, int? groupId) {
    final index = _projects.indexWhere((p) => p.id == projectId);
    if (index >= 0) {
      _projects = [..._projects];
      _projects[index] = _projects[index].copyWith(groupId: groupId);
    }
  }
}
