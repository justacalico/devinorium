part of 'package:devinorium_frontend/state/app_state.dart';

mixin FilesPanelStore on AppStateBase {
  static const int _fileChunkSize = 100;

  @override
  FileTreeNode _filesTreeRoot = FileTreeNode.root();
  @override
  bool _filesPanelOpen = false;
  @override
  String _filesError = '';
  @override
  String? _filesScopeKey;

  int _filesTreeVersion = 0;
  List<FileTreeRow>? _filesTreeRowsCache;
  int _filesTreeRowsCacheVersion = -1;

  @override
  bool get filesPanelOpen => _filesPanelOpen;

  /// The scope the loaded file tree was fetched under. Compare with
  /// [activeFilesScopeKey] to know when the tree is stale.
  @override
  String? get filesScopeKey => _filesScopeKey;

  /// Identity of the directory the file tree should be rooted at right now:
  /// the active thread's worktree when it runs in worktree mode, otherwise
  /// the active project root.
  @override
  String? get activeFilesScopeKey {
    final wt = _activeFilesWorktreePath;
    if (wt != null) return 'worktree:$wt';
    final pid = _activeProjectId;
    return pid == null ? null : 'project:$pid';
  }

  /// The thread whose working directory the file tree follows, if one is
  /// active. Falls back to the sidebar list entry while the detail loads.
  Thread? get _activeFilesThread {
    final detail = activeThreadDetail?.thread;
    if (detail != null) return detail;
    final id = _activeThreadId;
    return id == null ? null : _threadById(id);
  }

  /// The active thread's worktree path when it actually runs there.
  String? get _activeFilesWorktreePath {
    final thread = _activeFilesThread;
    if (thread == null || thread.envMode != 'worktree') return null;
    final wt = thread.worktreePath;
    return (wt == null || wt.isEmpty) ? null : wt;
  }

  @override
  Thread? _threadById(String id) {
    for (final t in _threads) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Map a tree-relative path to the path the file APIs expect. Inside a
  /// worktree scope the absolute path is sent so the request stays pinned
  /// to the loaded tree root even if the active scope has moved on.
  @override
  String filesScopedPath(String path) {
    const prefix = 'worktree:';
    final key = _filesScopeKey;
    if (key == null || p.isAbsolute(path) || !key.startsWith(prefix)) {
      return path;
    }
    return p.normalize(p.join(key.substring(prefix.length), path));
  }

  /// The thread_id to attach to file API calls. Sent only while the loaded
  /// tree is a worktree scope; for a project-scope tree the relative paths
  /// must keep resolving at the project root even if the thread has since
  /// moved into a worktree.
  @override
  String? get filesApiThreadId =>
      _filesScopeKey?.startsWith('worktree:') == true ? _activeThreadId : null;

  @override
  List<DirEntry> get filesEntries =>
      _filesTreeRoot.children.map((n) => n.entry).toList();
  @override
  FileTreeNode get filesTreeRoot => _filesTreeRoot;
  @override
  List<FileTreeRow> get filesTreeRows {
    if (_filesTreeRowsCache == null ||
        _filesTreeRowsCacheVersion != _filesTreeVersion) {
      _filesTreeRowsCache = buildFileTreeRows(_filesTreeRoot, indent: 0);
      _filesTreeRowsCacheVersion = _filesTreeVersion;
    }
    return _filesTreeRowsCache!;
  }

  void _bumpFilesTreeVersion() => _filesTreeVersion++;

  @override
  String get filesError => _filesError;
  @override
  bool get hasMoreFiles => _filesTreeRoot.hasMore;
  @override
  bool get isLoadingMoreFiles => _filesTreeRoot.isLoadingMore;

  @override
  Future<void> openFilesPanel() async {
    _filesPanelOpen = true;
    _filesError = '';
    _filesTreeRoot = FileTreeNode.root()..isLoading = true;
    _filesScopeKey = activeFilesScopeKey;
    _bumpFilesTreeVersion();
    notifyListeners();
    if (_activeProjectId == null) {
      _filesTreeRoot.isLoading = false;
      _filesTreeRoot.children = [];
      _bumpFilesTreeVersion();
      notifyListeners();
      return;
    }
    await _loadChildren(_filesTreeRoot);
    _filesError = _filesTreeRoot.error;
    notifyListeners();
  }

  @override
  void closeFilesPanel() {
    _filesPanelOpen = false;
    notifyListeners();
  }

  @override
  Future<void> reloadFiles() async {
    if (_filesTreeRoot.isLoading) return;
    _filesTreeRoot = FileTreeNode.root()..hasMore = true;
    _filesScopeKey = activeFilesScopeKey;
    _bumpFilesTreeVersion();
    if (_activeProjectId == null) {
      _filesTreeRoot.children = [];
      _filesError = '';
      notifyListeners();
      return;
    }
    await _loadChildren(_filesTreeRoot);
    _filesError = _filesTreeRoot.error;
    notifyListeners();
  }

  @override
  Future<void> toggleFilesFolder(FileTreeNode node) async {
    if (!node.entry.isDir || node.isLoading) return;
    node.isExpanded = !node.isExpanded;
    _bumpFilesTreeVersion();
    if (node.isExpanded && node.children.isEmpty) {
      await _loadChildren(node);
    } else {
      notifyListeners();
    }
  }

  @override
  Future<void> loadMoreFiles({FileTreeNode? node}) async {
    if (_activeProjectId == null) return;
    final target = node ?? _filesTreeRoot;
    if (target.isLoading || target.isLoadingMore || !target.hasMore) return;
    target.isLoadingMore = true;
    notifyListeners();
    try {
      final chunk = await api.listFiles(
        path: target.fullPathString.isEmpty
            ? null
            : filesScopedPath(target.fullPathString),
        projectId: _activeProjectId,
        threadId: filesApiThreadId,
        limit: _fileChunkSize,
        offset: target.offset,
      );
      final existing = <String>{
        for (final child in target.children) child.name,
      };
      final fresh = chunk.where((e) => !existing.contains(e.name)).toList();
      target.children = [
        ...target.children,
        ...fresh.map((e) => FileTreeNode(path: target.fullPath, entry: e)),
      ];
      target.offset += chunk.length;
      target.hasMore = chunk.length == _fileChunkSize;
      _bumpFilesTreeVersion();
    } catch (e) {
      target.error = '$e';
      target.hasMore = false;
      if (target == _filesTreeRoot) _filesError = '$e';
      _bumpFilesTreeVersion();
    }
    target.isLoadingMore = false;
    notifyListeners();
  }

  @override
  @visibleForTesting
  void setFilesEntries(List<DirEntry> entries) {
    _filesTreeRoot = FileTreeNode.root()
      ..children =
          entries.map((e) => FileTreeNode(path: const [], entry: e)).toList()
      ..offset = entries.length
      ..hasMore = false;
    _filesScopeKey = activeFilesScopeKey;
    _filesError = '';
    _bumpFilesTreeVersion();
    notifyListeners();
  }

  @override
  Future<void> mkdir(String name) async {
    if (_activeProjectId == null) return;
    final full = name.trim();
    try {
      await api.mkdir(
        filesScopedPath(full),
        projectId: _activeProjectId,
        threadId: filesApiThreadId,
      );
      _filesError = '';
      notifyListeners();
      await _refreshParentForPath(full);
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    if (_activeProjectId == null) return;
    final scoped = filesScopedPath(path);
    try {
      await api.deleteFile(
        scoped,
        projectId: _activeProjectId,
        threadId: filesApiThreadId,
      );
      for (final tab in editorTabs.toList().reversed) {
        if (tab.path == scoped || tab.path.startsWith('$scoped/')) {
          closeEditorTab(tab.path);
        }
      }
      _filesError = '';
      notifyListeners();
      await _refreshParentForPath(path);
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }

  Future<void> _loadChildren(FileTreeNode node) async {
    if (_activeProjectId == null) {
      node.isLoading = false;
      node.children = [];
      _bumpFilesTreeVersion();
      notifyListeners();
      return;
    }
    node.isLoading = true;
    node.error = '';
    node.children = [];
    // Capture the scope now: the thread's worktree can appear mid-request
    // (auto-created on send), and the loaded tree must be marked with the
    // scope the request actually ran under.
    final scope = _filesScopeKey;
    _bumpFilesTreeVersion();
    notifyListeners();
    try {
      final chunk = await api.listFiles(
        path: node.fullPathString.isEmpty
            ? null
            : filesScopedPath(node.fullPathString),
        projectId: _activeProjectId,
        threadId: filesApiThreadId,
        limit: _fileChunkSize,
        offset: 0,
      );
      node.children = chunk
          .map((e) => FileTreeNode(path: node.fullPath, entry: e))
          .toList();
      node.offset = chunk.length;
      node.hasMore = chunk.length == _fileChunkSize;
      if (node.fullPath.isEmpty && identical(node, _filesTreeRoot)) {
        _filesScopeKey = scope;
      }
    } catch (e) {
      node.error = '$e';
      node.hasMore = false;
    }
    _bumpFilesTreeVersion();
    node.isLoading = false;
    notifyListeners();
  }

  Future<void> _refreshParentForPath(String fullPath) async {
    final parent = _findParentForPath(fullPath);
    if (parent == null) {
      await reloadFiles();
      return;
    }
    if (parent.isLoading) return;
    await _loadChildren(parent);
    if (parent == _filesTreeRoot) {
      _filesError = parent.error;
      notifyListeners();
    }
  }

  FileTreeNode? _findParentForPath(String fullPath) {
    final segments = fullPath.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return _filesTreeRoot;
    final parentPath = segments.sublist(0, segments.length - 1);
    return _findNodeByPath(_filesTreeRoot, parentPath);
  }

  FileTreeNode? _findNodeByPath(FileTreeNode current, List<String> path) {
    if (_samePath(current.fullPath, path)) return current;
    for (final child in current.children) {
      final found = _findNodeByPath(child, path);
      if (found != null) return found;
    }
    return null;
  }

  bool _samePath(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
