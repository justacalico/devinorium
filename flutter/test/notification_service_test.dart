import 'package:devinorium_frontend/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationService', () {
    test('defaults to disabled', () {
      final svc = NotificationService();
      expect(svc.notificationsEnabled, isFalse);
    });

    test('setNotificationsEnabled toggles state', () {
      final svc = NotificationService();
      svc.setNotificationsEnabled(true);
      expect(svc.notificationsEnabled, isTrue);
      svc.setNotificationsEnabled(false);
      expect(svc.notificationsEnabled, isFalse);
    });

    test('notifyThreadCompleted does nothing when disabled', () {
      final svc = NotificationService();
      svc.notifyThreadCompleted(title: 'test', failed: false);
    });

    test('notifyThreadCompleted does not throw when enabled', () {
      final svc = NotificationService();
      svc.setNotificationsEnabled(true);
      svc.notifyThreadCompleted(title: 'test', failed: false);
      svc.notifyThreadCompleted(title: 'test', failed: true);
    });
  });
}
