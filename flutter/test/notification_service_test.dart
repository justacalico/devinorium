import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationService', () {
    test('defaults to disabled', () {
      final svc = NotificationService();
      expect(svc.notificationsEnabled, isFalse);
    });

    test('setNotificationsEnabled toggles state', () async {
      final svc = NotificationService();
      await svc.setNotificationsEnabled(true);
      expect(svc.notificationsEnabled, isTrue);
      await svc.setNotificationsEnabled(false);
      expect(svc.notificationsEnabled, isFalse);
    });

    test('push is unsupported in the test environment', () {
      final svc = NotificationService();
      expect(svc.pushSupported, isFalse);
      expect(svc.pushStatus, 'unsupported');
    });

    test('permissionState is granted on desktop test platforms', () async {
      final svc = NotificationService();
      expect(await svc.permissionState(), 'granted');
    });

    test('initialThreadId is null without a launch notification', () {
      final svc = NotificationService();
      expect(svc.initialThreadId(), isNull);
    });

    test(
      'syncPush stays unsupported without a platform push backend',
      () async {
        final svc = NotificationService();
        final status = await svc.syncPush(
          api: ApiService(),
          lang: 'en',
          enabled: true,
          allowPrompt: true,
        );
        expect(status, 'unsupported');
      },
    );

    test('notifyRunEvent does nothing when disabled', () {
      final svc = NotificationService();
      svc.notifyRunEvent(threadId: 't1', title: 'test', kind: 'completed');
    });

    test('notifyRunEvent does not throw when enabled', () async {
      final svc = NotificationService();
      await svc.setNotificationsEnabled(true);
      svc.notifyRunEvent(threadId: 't1', title: 'test', kind: 'completed');
      svc.notifyRunEvent(threadId: 't1', title: 'test', kind: 'failed');
      svc.notifyRunEvent(threadId: 't1', title: 'test', kind: 'permission');
      svc.notifyRunEvent(threadId: 't1', title: 'test', kind: 'ask');
    });
  });
}
