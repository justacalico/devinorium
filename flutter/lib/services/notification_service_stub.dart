import '../l10n/global_l10n.dart';

/// Stub implementation of NotificationService for non-web platforms
/// and the VM test runner.
class NotificationService {
  bool _notificationsEnabled = false;
  bool _soundEnabled = false;

  bool get notificationsEnabled => _notificationsEnabled;
  bool get soundEnabled => _soundEnabled;

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
  }

  void setSoundEnabled(bool enabled) {
    _soundEnabled = enabled;
  }

  void notifyThreadCompleted({required String title, required bool failed}) {
    // No-op on non-web platforms.
  }
}
