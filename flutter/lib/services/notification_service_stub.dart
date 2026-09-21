import '../api/api_service.dart';

/// No-op implementation for platforms with no notification surface (tests,
/// and any target the conditional import has no real backend for).
class NotificationService {
  bool _notificationsEnabled = false;

  void Function(String threadId)? onOpenThread;

  bool get notificationsEnabled => _notificationsEnabled;

  bool get pushSupported => false;

  String get pushStatus => 'unsupported';

  void initialize() {}

  String? initialThreadId() => null;

  Future<String> permissionState() async => 'unsupported';

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
  }

  void notifyRunEvent({
    required String threadId,
    required String title,
    required String kind,
  }) {}

  Future<String> syncPush({
    required ApiService api,
    required String lang,
    required bool enabled,
    bool allowPrompt = false,
  }) async => 'unsupported';
}
