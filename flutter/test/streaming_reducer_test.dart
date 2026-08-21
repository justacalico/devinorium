import 'package:devinorium_frontend/api/api_types.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/streaming_reducer.dart';
import 'package:devinorium_frontend/state/streaming_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reduceStreamingEvent thinkingActive', () {
    test('is true when the last part is thinking', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'part',
          '{"type":"thinking","content":"hmm"}',
          id: '1',
        ),
      );
      expect(res.snapshot.thinkingActive, isTrue);
    });

    test('is false when the last part is text', () {
      var snapshot = StreamingSnapshot.empty;
      var res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent(
          'part',
          '{"type":"thinking","content":"hmm"}',
          id: '1',
        ),
      );
      snapshot = res.snapshot;
      res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent(
          'part',
          '{"type":"text","content":"hello"}',
          id: '2',
        ),
      );
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('toggles back to true on a second thinking block', () {
      var snapshot = StreamingSnapshot.empty;
      for (final (seq, payload) in [
        (1, '{"type":"thinking","content":"first think"}'),
        (2, '{"type":"text","content":"switched"}'),
        (3, '{"type":"thinking","content":"second think"}'),
      ]) {
        final res = reduceStreamingEvent(
          detail: null,
          snapshot: snapshot,
          event: SseEvent('part', payload, id: '$seq'),
        );
        snapshot = res.snapshot;
      }
      expect(snapshot.parts, hasLength(3));
      expect(snapshot.parts.last.type, 'thinking');
      expect(snapshot.thinkingActive, isTrue);
    });

    test('stays false when interleaved blocks end on text', () {
      var snapshot = StreamingSnapshot.empty;
      for (final (seq, payload) in [
        (1, '{"type":"thinking","content":"first think"}'),
        (2, '{"type":"text","content":"a"}'),
        (3, '{"type":"thinking","content":"second think"}'),
        (4, '{"type":"text","content":"b"}'),
      ]) {
        final res = reduceStreamingEvent(
          detail: null,
          snapshot: snapshot,
          event: SseEvent('part', payload, id: '$seq'),
        );
        snapshot = res.snapshot;
      }
      expect(snapshot.parts.last.type, 'text');
      expect(snapshot.thinkingActive, isFalse);
    });

    test('is false for an empty snapshot', () {
      expect(StreamingSnapshot.empty.thinkingActive, isFalse);
    });
  });

  group('reduceStreamingEvent ask_request', () {
    test('sets pendingAsk from event', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'ask_request',
          '{"request_id":"a1","message":"Need input","questions":[{"id":"q1","prompt":"Value","field_type":"text"}]}',
          id: '1',
        ),
      );
      expect(res.snapshot.pendingAsk, isNotNull);
      expect(res.snapshot.pendingAsk!.requestId, 'a1');
      expect(res.snapshot.pendingAsk!.questions, hasLength(1));
      expect(res.snapshot.pendingAsk!.questions[0].fieldType, 'text');
    });

    test('clears pendingAsk on user_message', () {
      var snapshot = StreamingSnapshot.empty.copyWith(
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(id: 'q1', prompt: 'Value', fieldType: 'text'),
          ],
        ),
      );
      final res = reduceStreamingEvent(
        detail: ThreadDetail(thread: Thread(id: 't1', title: 'T', projectId: 1, model: '', permissionMode: 'normal', createdAt: '', updatedAt: '')),
        snapshot: snapshot,
        event: SseEvent('user_message', '{"role":"user","content":"hi"}', id: '2'),
      );
      expect(res.snapshot.pendingAsk, isNull);
    });

    test('clears pendingAsk on done', () {
      var snapshot = StreamingSnapshot.empty.copyWith(
        pendingAsk: AskRequest(
          requestId: 'a1',
          message: 'Need input',
          questions: [
            AskQuestion(id: 'q1', prompt: 'Value', fieldType: 'text'),
          ],
        ),
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '3'),
      );
      expect(res.snapshot.pendingAsk, isNull);
      expect(res.snapshot.phase, StreamPhase.completed);
    });
  });

  group('runSnapshotFromJson', () {
    test('restores pendingAsk from run snapshot', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'ask_request': {
          'request_id': 'a1',
          'message': 'Need input',
          'questions': [
            {'id': 'q1', 'prompt': 'Value', 'field_type': 'text'},
          ],
        },
      });
      expect(snapshot.pendingAsk, isNotNull);
      expect(snapshot.pendingAsk!.requestId, 'a1');
      expect(snapshot.phase, StreamPhase.running);
    });

    test('extracts started_at from run snapshot', () {
      final snapshot = runSnapshotFromJson({
        'status': 'running',
        'started_at': '2025-01-01T00:00:00Z',
      });
      expect(snapshot.startedAt, '2025-01-01T00:00:00Z');
    });

    test('started_at is null when not present', () {
      final snapshot = runSnapshotFromJson({'status': 'running'});
      expect(snapshot.startedAt, isNull);
    });
  });

  group('startedAt lifecycle', () {
    test('state event sets startedAt', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'state',
          '{"status":"running","started_at":"2025-01-01T00:00:00Z"}',
          id: '1',
        ),
      );
      expect(res.snapshot.startedAt, '2025-01-01T00:00:00Z');
    });

    test('done event clears startedAt', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '2'),
      );
      expect(res.snapshot.startedAt, isNull);
    });

    test('stopped event sets stopped phase', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('stopped', '{}', id: '2'),
      );
      expect(res.snapshot.phase, StreamPhase.stopped);
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('stopped event keeps parts visible', () {
      final parts = <MessagePart>[
        MessagePart.thinking(content: 'Let me think...'),
        MessagePart.text(content: 'Here is my answer'),
      ];
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        parts: parts,
        thinkingActive: true,
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('stopped', '{}', id: '2'),
      );
      expect(res.snapshot.phase, StreamPhase.stopped);
      expect(res.snapshot.parts, equals(parts));
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('done event clears parts', () {
      final parts = <MessagePart>[
        MessagePart.thinking(content: 'Let me think...'),
        MessagePart.text(content: 'Here is my answer'),
      ];
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        parts: parts,
        thinkingActive: true,
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('done', '{"role":"assistant","content":"ok"}', id: '2'),
      );
      expect(res.snapshot.parts, isEmpty);
      expect(res.snapshot.thinkingActive, isFalse);
    });

    test('error event clears startedAt', () {
      final snapshot = StreamingSnapshot(
        phase: StreamPhase.running,
        startedAt: '2025-01-01T00:00:00Z',
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: snapshot,
        event: SseEvent('error', 'something broke', id: '2'),
      );
      expect(res.snapshot.startedAt, isNull);
    });

    test('user_message event sets startedAt to now', () {
      final detail = ThreadDetail(
        thread: Thread(
          id: 't1',
          title: 'Test',
          projectId: 1,
          model: 'm1',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: [],
        totalMessages: 0,
      );
      final res = reduceStreamingEvent(
        detail: detail,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'user_message',
          '{"role":"user","content":"hello"}',
          id: '1',
        ),
      );
      expect(res.snapshot.startedAt, isNotNull);
      final parsed = DateTime.tryParse(res.snapshot.startedAt!);
      expect(parsed, isNotNull);
      final diff = DateTime.now().toUtc().difference(parsed!).inSeconds.abs();
      expect(diff, lessThan(5));
    });
  });
}
