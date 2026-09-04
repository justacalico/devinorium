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
  bool get filesPanelOpen => _filesPanelOpen;
  @override
  List<DirEntry> get filesEntries =>
      _filesTreeRoot.children.map((n) => n.entry).toList();
  @override
  FileTreeNode get filesTreeRoot => _filesTreeRoot;
  @override
  List<FileTreeRow> get filesTreeRows =>
      buildFileTreeRows(_filesTreeRoot, indent: 0);
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
    notifyListeners();
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
    await _loadChildren(_filesTreeRoot);
    _filesError = _filesTreeRoot.error;
    notifyListeners();
  }

  @override
  Future<void> toggleFilesFolder(FileTreeNode node) async {
    if (!node.entry.isDir || node.isLoading) return;
    node.isExpanded = !node.isExpanded;
    if (node.isExpanded && node.children.isEmpty) {
      await _loadChildren(node);
    }
    notifyListeners();
  }

  @override
  Future<void> loadMoreFiles({FileTreeNode? node}) async {
    final target = node ?? _filesTreeRoot;
    if (target.isLoading || target.isLoadingMore || !target.hasMore) return;
    target.isLoadingMore = true;
    notifyListeners();
    try {
      final chunk = await api.listFiles(
        path: target.fullPathString.isEmpty ? null : target.fullPathString,
        projectId: _activeProjectId,
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
    } catch (e) {
      target.error = '$e';
      target.hasMore = false;
      if (target == _filesTreeRoot) _filesError = '$e';
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
    _filesError = '';
    notifyListeners();
  }

  @override
  Future<void> mkdir(String name) async {
    final full = name.trim();
    try {
      await api.mkdir(full, projectId: _activeProjectId);
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
    try {
      await api.deleteFile(path, projectId: _activeProjectId);
      for (final tab in editorTabs.toList().reversed) {
        if (tab.path == path || tab.path.startsWith('$path/')) {
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
    node.isLoading = true;
    node.error = '';
    node.children = [];
    notifyListeners();
    try {
      final chunk = await api.listFiles(
        path: node.fullPathString.isEmpty ? null : node.fullPathString,
        projectId: _activeProjectId,
        limit: _fileChunkSize,
        offset: 0,
      );
      node.children = chunk
          .map((e) => FileTreeNode(path: node.fullPath, entry: e))
          .toList();
      node.offset = chunk.length;
      node.hasMore = chunk.length == _fileChunkSize;
    } catch (e) {
      node.error = '$e';
      node.hasMore = false;
    }
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
