import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../l10n/global_l10n.dart';

/// Handles browser notifications and completion sound when a thread run
/// finishes while the tab is not active.
class NotificationService {
  bool _notificationsEnabled = false;
  bool _soundEnabled = false;

  bool get notificationsEnabled => _notificationsEnabled;
  bool get soundEnabled => _soundEnabled;

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
    if (enabled) _ensurePermission();
  }

  void setSoundEnabled(bool enabled) {
    _soundEnabled = enabled;
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
    if (_soundEnabled) _playSound();
  }

  void _playSound() {
    try {
      final ctx = web.AudioContext();
      final osc = ctx.createOscillator();
      final gain = ctx.createGain();
      osc.frequency.value = 880;
      gain.gain.value = 0.1;
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start();
      osc.stop(ctx.currentTime + 0.15);
    } catch (_) {}
  }
}
