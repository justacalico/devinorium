/// Handles notifications and completion sound when a thread run finishes.
///
/// Platform-specific implementations:
/// - Web: browser Notifications API + Web Audio API
/// - Desktop (Linux/macOS/Windows): native OS commands (notify-send, osascript, PowerShell)
/// - Mobile/stub: no-op
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
    // No-op on unsupported platforms.
  }
}
