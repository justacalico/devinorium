part of 'package:devinorium_frontend/state/app_state.dart';

mixin ThreadRefsStore on AppStateBase {
  // Same list-identity rule as attachments: the composer's Selector only
  // rebuilds when the list instance changes, so every mutation reassigns.
  @override
  List<ThreadReference> _threadReferences = [];
  @override
  List<ThreadReference> get threadReferences =>
      _activeStore?.threadReferences ?? _threadReferences;

  @override
  void addThreadReference(ThreadReference ref) {
    if (ref.id.isEmpty) return;
    final store = _activeStore;
    final activeId = store?.threadId ?? _activeThreadId;
    // Referencing the thread being composed would only echo the visible
    // conversation back at the model.
    if (ref.id == activeId) return;
    final current = store?.threadReferences ?? _threadReferences;
    if (current.any((r) => r.id == ref.id)) return;
    final next = [...current, ref];
    if (store != null) {
      store.threadReferences = next;
    } else {
      _threadReferences = next;
    }
    notifyListeners();
  }

  @override
  void removeThreadReference(int index) {
    final store = _activeStore;
    if (store != null) {
      store.threadReferences = [...store.threadReferences]..removeAt(index);
    } else {
      _threadReferences = [..._threadReferences]..removeAt(index);
    }
    notifyListeners();
  }

  @override
  void clearThreadReferences() {
    final store = _activeStore;
    if (store != null) {
      store.threadReferences = [];
    } else {
      _threadReferences = [];
    }
    notifyListeners();
  }
}
