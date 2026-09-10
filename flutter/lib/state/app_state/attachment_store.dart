part of 'package:devinorium_frontend/state/app_state.dart';

mixin AttachmentStore on AppStateBase {
  // The composer reads this list through a Selector, so every mutation must
  // produce a new list instance; mutating in place keeps the old identity and
  // the chip row would not rebuild until some unrelated state change.
  @override
  List<({String filename, String mime, Uint8List bytes})> _attachments = [];
  @override
  List<({String filename, String mime, Uint8List bytes})> get attachments =>
      _activeStore?.attachments ?? _attachments;
  @override
  void addAttachments(
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    if (files.isEmpty) return;
    final store = _activeStore;
    if (store != null) {
      store.attachments = [...store.attachments, ...files];
    } else {
      _attachments = [..._attachments, ...files];
    }
    notifyListeners();
  }

  @override
  void removeAttachment(int index) {
    final store = _activeStore;
    if (store != null) {
      store.attachments = [...store.attachments]..removeAt(index);
    } else {
      _attachments = [..._attachments]..removeAt(index);
    }
    notifyListeners();
  }

  @override
  void clearAttachments() {
    final store = _activeStore;
    if (store != null) {
      store.attachments = [];
    } else {
      _attachments = [];
    }
    notifyListeners();
  }
}
