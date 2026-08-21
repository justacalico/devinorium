import 'package:devinorium_frontend/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationService', () {
    test('defaults to disabled', () {
      final svc = NotificationService();
      expect(svc.notificationsEnabled, isFalse);
      expect(svc.soundEnabled, isFalse);
    });

    test('setNotificationsEnabled toggles state', () {
      final svc = NotificationService();
      svc.setNotificationsEnabled(true);
      expect(svc.notificationsEnabled, isTrue);
      svc.setNotificationsEnabled(false);
      expect(svc.notificationsEnabled, isFalse);
    });

    test('setSoundEnabled toggles state', () {
      final svc = NotificationService();
      svc.setSoundEnabled(true);
      expect(svc.soundEnabled, isTrue);
      svc.setSoundEnabled(false);
      expect(svc.soundEnabled, isFalse);
    });

    test('notifyThreadCompleted does nothing when disabled', () {
      final svc = NotificationService();
      // Should not throw even though web APIs aren't available in tests.
      svc.notifyThreadCompleted(title: 'test', failed: false);
    });

    test('notifyThreadCompleted does not throw when enabled', () {
      final svc = NotificationService();
      svc.setNotificationsEnabled(true);
      svc.setSoundEnabled(true);
      // Web APIs aren't available in unit tests, but the try/catch
      // should swallow the errors.
      svc.notifyThreadCompleted(title: 'test', failed: false);
      svc.notifyThreadCompleted(title: 'test', failed: true);
    });
  });
}
