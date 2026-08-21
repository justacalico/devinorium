import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../l10n/global_l10n.dart';

class NotificationService {
  bool _notificationsEnabled = false;

  bool get notificationsEnabled => _notificationsEnabled;

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
    if (enabled) _ensurePermission();
  }

  void _ensurePermission() {
    try {
      if (web.Notification.permission != 'granted') {
        web.Notification.requestPermission().toDart.then((_) {});
      }
    } catch (_) {}
  }

  bool get _isTabHidden {
    try {
      return web.document.hidden;
    } catch (_) {
      return false;
    }
  }

  void notifyThreadCompleted({required String title, required bool failed}) {
    if (!_notificationsEnabled) return;
    if (!_isTabHidden) return;
    try {
      final l = appL10n;
      final body = failed
          ? l.threadFailedBody(title)
          : l.threadCompletedBody(title);
      web.Notification(
        failed ? l.threadFailedTitle : l.threadCompletedTitle,
        web.NotificationOptions(body: body),
      );
    } catch (_) {}
  }
}
