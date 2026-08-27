part of 'package:devinorium_frontend/state/app_state.dart';

mixin FilesPanelStore on AppStateBase {
  static const int _fileChunkSize = 100;
  @override
  int _filesOffset = 0;
  @override
  bool _filesHasMore = true;
  @override
  bool _loadingMoreFiles = false;
  @override
  bool _filesPanelOpen = false;
  @override
  List<String> _filesPath = [];
  @override
  List<DirEntry> _filesEntries = [];
  @override
  String _filesError = '';
  @override
  bool get filesPanelOpen => _filesPanelOpen;
  @override
  List<String> get filesPath => _filesPath;
  @override
  List<DirEntry> get filesEntries => _filesEntries;
  @override
  String get filesError => _filesError;
  @override
  bool get hasMoreFiles => _filesHasMore;
  @override
  bool get isLoadingMoreFiles => _loadingMoreFiles;
  @override
  Future<void> openFilesPanel() async {
    _filesPanelOpen = true;
    _filesPath = [];
    _filesOffset = 0;
    _filesHasMore = true;
    _filesError = '';
    notifyListeners();
    await reloadFiles();
  }
  @override
  void closeFilesPanel() {
    _filesPanelOpen = false;
    notifyListeners();
  }
  @override
  Future<void> navigateFilesInto(String name) async {
    _filesPath = [..._filesPath, name];
    _filesOffset = 0;
    _filesHasMore = true;
    notifyListeners();
    await reloadFiles();
  }
  @override
  Future<void> navigateFilesTo(List<String> path) async {
    _filesPath = path;
    _filesOffset = 0;
    _filesHasMore = true;
    notifyListeners();
    await reloadFiles();
  }
  @override
  Future<void> reloadFiles() async {
    _filesOffset = 0;
    _filesHasMore = true;
    final path = _filesPath.join('/');
    try {
      final chunk = await api.listFiles(
        path: path.isEmpty ? null : path,
        projectId: _activeProjectId,
        limit: _fileChunkSize,
        offset: _filesOffset,
      );
      _filesEntries = chunk;
      _filesOffset = chunk.length;
      _filesHasMore = chunk.length == _fileChunkSize;
      _filesError = '';
    } catch (e) {
      _filesError = '$e';
      _filesHasMore = false;
    }
    notifyListeners();
  }
  @override
  Future<void> loadMoreFiles() async {
    if (!_filesHasMore || _loadingMoreFiles) return;
    _loadingMoreFiles = true;
    notifyListeners();
    try {
      final path = _filesPath.join('/');
      final chunk = await api.listFiles(
        path: path.isEmpty ? null : path,
        projectId: _activeProjectId,
        limit: _fileChunkSize,
        offset: _filesOffset,
      );
      final existing = <String>{for (final e in _filesEntries) e.name};
      final fresh = chunk.where((e) => !existing.contains(e.name)).toList();
      _filesEntries = [..._filesEntries, ...fresh];
      _filesOffset += fresh.length;
      _filesHasMore = chunk.length == _fileChunkSize;
    } catch (e) {
      _filesError = '$e';
      _filesHasMore = false;
    }
    _loadingMoreFiles = false;
    notifyListeners();
  }
  @visibleForTesting
  @override
  void setFilesEntries(List<DirEntry> entries) {
    _filesEntries = entries;
    _filesError = '';
    notifyListeners();
  }
  @override
  Future<void> mkdir(String name) async {
    final p = _filesPath.join('/');
    final full = p.isEmpty ? name.trim() : '$p/${name.trim()}';
    try {
      await api.mkdir(full, projectId: _activeProjectId);
      _filesError = '';
      notifyListeners();
      await reloadFiles();
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }
  @override
  Future<void> deleteFile(String name, {bool skipConfirm = false}) async {
    final p = _filesPath.join('/');
    final full = p.isEmpty ? name : '$p/$name';
    try {
      await api.deleteFile(full, projectId: _activeProjectId);
      _filesError = '';
      notifyListeners();
      await reloadFiles();
    } catch (e) {
      _filesError = '$e';
      notifyListeners();
    }
  }
}
