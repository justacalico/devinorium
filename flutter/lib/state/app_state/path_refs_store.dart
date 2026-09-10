part of 'package:devinorium_frontend/state/app_state.dart';

mixin PathRefsStore on AppStateBase {
  // Same list-identity rule as attachments: the composer's Selector only
  // rebuilds when the list instance changes, so every mutation reassigns.
  @override
  List<PathRef> _pathRefs = [];
  @override
  List<PathRef> get pathRefs => _activeStore?.pathRefs ?? _pathRefs;

  @override
  void addPathRef(String path, {required bool isDir}) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    final store = _activeStore;
    final current = store?.pathRefs ?? _pathRefs;
    if (current.any((r) => r.path == trimmed)) return;
    final next = [...current, (path: trimmed, isDir: isDir)];
    if (store != null) {
      store.pathRefs = next;
    } else {
      _pathRefs = next;
    }
    notifyListeners();
  }

  @override
  void removePathRef(int index) {
    final store = _activeStore;
    if (store != null) {
      store.pathRefs = [...store.pathRefs]..removeAt(index);
    } else {
      _pathRefs = [..._pathRefs]..removeAt(index);
    }
    notifyListeners();
  }
}
