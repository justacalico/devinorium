import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/services/notification_service.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

User _user() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

Thread _thread(String id, {String title = 'A thread'}) => Thread(
  id: id,
  title: title,
  projectId: 1,
  model: 'm',
  permissionMode: 'normal',
  createdAt: 'now',
  updatedAt: 'now',
);

class _RecordingNotifications extends NotificationService {
  bool enabled = true;
  final calls = <({String threadId, String title, String kind})>[];

  @override
  bool get notificationsEnabled => enabled;

  @override
  void notifyRunEvent({
    required String threadId,
    required String title,
    required String kind,
  }) {
    calls.add((threadId: threadId, title: title, kind: kind));
  }
}

SseEvent _runStatus(
  String tid,
  String status, {
  String? runId,
  String? attention,
}) => SseEvent(
  'run_status',
  jsonEncode({
    'thread_id': tid,
    'run_id': runId ?? 'r-$tid',
    'status': status,
    'attention': ?attention,
    'updated_at': 'now',
  }),
);

void main() {
  group('NotificationsStore', () {
    test('completed on a background thread notifies', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(
        user: _user(),
        notifications: fake,
        threads: [_thread('t1', title: 'Build site')],
      );
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(fake.calls, hasLength(1));
      expect(fake.calls.single.kind, 'completed');
      expect(fake.calls.single.threadId, 't1');
      expect(fake.calls.single.title, 'Build site');
    });

    test('failed and stopped notify', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(_runStatus('t1', 'failed'));
      state.handleRunEventForTest(_runStatus('t2', 'stopped'));
      expect(fake.calls.map((c) => c.kind), ['failed', 'stopped']);
    });

    test('attention flags notify with their own kinds', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'permission'),
      );
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'ask'),
      );
      expect(fake.calls.map((c) => c.kind), ['permission', 'ask']);
    });

    test('plain running events stay silent', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      expect(fake.calls, isEmpty);
    });

    test('the same run event does not notify twice', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'permission'),
      );
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'permission'),
      );
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(fake.calls.map((c) => c.kind), ['permission', 'completed']);
    });

    test('snapshots hydrate without notifying', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(
        SseEvent(
          'runs',
          jsonEncode({
            'running_ids': ['t1'],
            'runs': [
              {
                'thread_id': 't1',
                'run_id': 'r-t1',
                'status': 'running',
                'attention': 'permission',
              },
            ],
          }),
        ),
      );
      expect(fake.calls, isEmpty);
    });

    test('the open thread stays quiet while the app is foregrounded', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(
        user: _user(),
        notifications: fake,
        threads: [_thread('t1')],
        activeThreadId: 't1',
      );
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(fake.calls, isEmpty);
    });

    test('the open thread notifies once the app is backgrounded', () {
      final fake = _RecordingNotifications();
      final state = AppState.test(
        user: _user(),
        notifications: fake,
        threads: [_thread('t1')],
        activeThreadId: 't1',
      );
      state.noteLifecycleState(AppLifecycleState.paused);
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(fake.calls, hasLength(1));
    });

    test('nothing fires while notifications are disabled', () {
      final fake = _RecordingNotifications()..enabled = false;
      final state = AppState.test(user: _user(), notifications: fake);
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      state.handleRunEventForTest(
        _runStatus('t2', 'running', attention: 'ask'),
      );
      expect(fake.calls, isEmpty);
    });
  });
}
