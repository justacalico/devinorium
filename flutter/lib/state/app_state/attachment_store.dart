part of 'package:devinorium_frontend/state/app_state.dart';

mixin AttachmentStore on AppStateBase {
  @override
  final List<({String filename, String mime, Uint8List bytes})> _attachments =
      [];
  @override
  List<({String filename, String mime, Uint8List bytes})> get attachments =>
      _activeStore?.attachments ?? _attachments;
  @override
  void addAttachments(
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    final store = _activeStore;
    if (store != null) {
      store.attachments.addAll(files);
    } else {
      _attachments.addAll(files);
    }
    notifyListeners();
  }
  @override
  void removeAttachment(int index) {
    final store = _activeStore;
    if (store != null) {
      store.attachments.removeAt(index);
    } else {
      _attachments.removeAt(index);
    }
    notifyListeners();
  }
  @override
  void clearAttachments() {
    final store = _activeStore;
    if (store != null) {
      store.attachments.clear();
    } else {
      _attachments.clear();
    }
    notifyListeners();
  }
}
