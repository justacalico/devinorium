import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
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

SseEvent _runStatus(String tid, String status, {String? attention}) =>
    SseEvent(
      'run_status',
      jsonEncode({
        'thread_id': tid,
        'run_id': 'r-$tid',
        'status': status,
        'attention': ?attention,
        'updated_at': 'now',
      }),
    );

void main() {
  group('RunEventsStore', () {
    test('a running event marks the thread as running', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      expect(state.runningThreadIds, contains('t1'));
      expect(state.threadRunStatus('t1'), 'running');
      expect(state.threadRunAttention('t1'), isNull);
    });

    test('two threads run independently', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      state.handleRunEventForTest(_runStatus('t2', 'running'));
      expect(state.runningThreadIds, containsAll(['t1', 't2']));

      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(state.runningThreadIds, isNot(contains('t1')));
      expect(state.runningThreadIds, contains('t2'));
      expect(state.threadRunStatus('t1'), 'completed');
      expect(state.threadRunStatus('t2'), 'running');
    });

    test('completed and failed statuses stay cached for the tile', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      state.handleRunEventForTest(_runStatus('t2', 'running'));
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      state.handleRunEventForTest(_runStatus('t2', 'failed'));
      expect(state.threadRunStatus('t1'), 'completed');
      expect(state.threadRunStatus('t2'), 'failed');
      expect(state.runningThreadIds, isEmpty);
    });

    test('a stopped run clears the running flag', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      state.handleRunEventForTest(_runStatus('t1', 'stopped'));
      expect(state.runningThreadIds, isNot(contains('t1')));
      expect(state.threadRunStatus('t1'), 'stopped');
    });

    test('attention events set and clear the pending flag', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'permission'),
      );
      expect(state.threadRunAttention('t1'), 'permission');

      state.handleRunEventForTest(_runStatus('t1', 'running'));
      expect(state.threadRunAttention('t1'), isNull);

      state.handleRunEventForTest(_runStatus('t1', 'running', attention: 'ask'));
      expect(state.threadRunAttention('t1'), 'ask');

      // A terminal event clears the attention flag too.
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(state.threadRunAttention('t1'), isNull);
    });

    test('the runs snapshot seeds live runs and drops stale ones', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('gone', 'running'));
      state.handleRunEventForTest(
        SseEvent(
          'runs',
          jsonEncode({
            'running_ids': ['live'],
            'runs': [
              {
                'thread_id': 'live',
                'run_id': 'r-live',
                'status': 'running',
                'attention': 'ask',
              },
            ],
          }),
        ),
      );

      expect(state.runningThreadIds, ['live']);
      // A thread the runner no longer tracks loses its cached status and
      // falls back to its persisted last message.
      expect(state.threadRunStatus('gone'), isNull);
      expect(state.threadRunStatus('live'), 'running');
      expect(state.threadRunAttention('live'), 'ask');
    });

    test('the snapshot clears attention that was answered while away', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(
        _runStatus('t1', 'running', attention: 'permission'),
      );
      expect(state.threadRunAttention('t1'), 'permission');

      state.handleRunEventForTest(
        SseEvent(
          'runs',
          jsonEncode({
            'running_ids': ['t1'],
            'runs': [
              {'thread_id': 't1', 'run_id': 'r1', 'status': 'running'},
            ],
          }),
        ),
      );
      expect(state.threadRunAttention('t1'), isNull);
      expect(state.threadRunStatus('t1'), 'running');
    });

    test('the snapshot carries terminal runs that finished while away', () {
      final state = AppState.test(user: _user());
      state.handleRunEventForTest(_runStatus('t1', 'running'));
      state.handleRunEventForTest(
        SseEvent(
          'runs',
          jsonEncode({
            'running_ids': <String>[],
            'runs': [
              {'thread_id': 't1', 'run_id': 'r1', 'status': 'completed'},
            ],
          }),
        ),
      );
      expect(state.runningThreadIds, isEmpty);
      expect(state.threadRunStatus('t1'), 'completed');
    });

    test('malformed payloads are ignored', () {
      final state = AppState.test(user: _user());
      var notified = 0;
      state.addListener(() => notified++);

      state.handleRunEventForTest(SseEvent('run_status', 'not json'));
      state.handleRunEventForTest(SseEvent('run_status', '{"status":1}'));
      state.handleRunEventForTest(SseEvent('runs', '[]'));
      state.handleRunEventForTest(SseEvent('something_else', '{}'));

      expect(notified, 0);
      expect(state.runningThreadIds, isEmpty);
    });

    test('listeners fire for each transition', () {
      final state = AppState.test(user: _user());
      var notified = 0;
      state.addListener(() => notified++);

      state.handleRunEventForTest(_runStatus('t1', 'running'));
      state.handleRunEventForTest(_runStatus('t1', 'completed'));
      expect(notified, 2);
    });
  });
}
