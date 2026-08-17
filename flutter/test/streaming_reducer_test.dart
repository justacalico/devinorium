import 'package:devinorium_frontend/api/api_types.dart';
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
}
