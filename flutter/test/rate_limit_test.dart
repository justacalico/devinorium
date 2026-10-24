import 'package:devinorium_frontend/api/api_types.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/streaming_reducer.dart';
import 'package:devinorium_frontend/state/streaming_state.dart';
import 'package:devinorium_frontend/utils/thread_status.dart';
import 'package:devinorium_frontend/views/rate_limit_countdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const waitJson =
      '{"retry_at":"2026-10-24T18:04:00.000Z","attempt":2,"max_attempts":8,"message":"rate limited"}';

  group('reduceStreamingEvent rate_limit', () {
    test('sets rateLimit from rate_limit event', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', waitJson, id: '3'),
      );
      final wait = res.snapshot.rateLimit;
      expect(wait, isNotNull);
      expect(wait!.attempt, 2);
      expect(wait.maxAttempts, 8);
      expect(wait.retryAt, DateTime.parse('2026-10-24T18:04:00.000Z'));
      expect(wait.message, 'rate limited');
      expect(res.snapshot.phase, StreamPhase.running);
    });

    test('null payload clears the wait', () {
      final first = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', waitJson, id: '1'),
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: first.snapshot,
        event: SseEvent('rate_limit', 'null', id: '2'),
      );
      expect(res.snapshot.rateLimit, isNull);
    });

    test('malformed payload is ignored', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', 'not json', id: '1'),
      );
      expect(res.snapshot.rateLimit, isNull);
    });

    test('missing retry_at is ignored', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', '{"attempt":1}', id: '1'),
      );
      expect(res.snapshot.rateLimit, isNull);
    });

    test('state snapshot applies and clears rate_limit', () {
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent(
          'state',
          '{"status":"running","parts":[],"rate_limit":$waitJson}',
          id: '1',
        ),
      );
      expect(res.snapshot.rateLimit, isNotNull);

      final cleared = reduceStreamingEvent(
        detail: null,
        snapshot: res.snapshot,
        event: SseEvent(
          'state',
          '{"status":"running","parts":[],"rate_limit":null}',
          id: '2',
        ),
      );
      expect(cleared.snapshot.rateLimit, isNull);
    });

    test('terminal events clear the wait', () {
      final parked = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', waitJson, id: '1'),
      );
      expect(parked.snapshot.rateLimit, isNotNull);

      for (final ev in [
        SseEvent('done', '{}', id: '2'),
        SseEvent('error', 'boom', id: '2'),
        SseEvent('stopped', '{}', id: '2'),
      ]) {
        final res = reduceStreamingEvent(
          detail: null,
          snapshot: parked.snapshot,
          event: ev,
        );
        expect(res.snapshot.rateLimit, isNull, reason: ev.event);
      }
    });

    test('a stale rate_limit event behind lastSeq is skipped', () {
      final parked = reduceStreamingEvent(
        detail: null,
        snapshot: StreamingSnapshot.empty,
        event: SseEvent('rate_limit', waitJson, id: '5'),
      );
      final res = reduceStreamingEvent(
        detail: null,
        snapshot: parked.snapshot,
        event: SseEvent('rate_limit', 'null', id: '3'),
      );
      expect(res.snapshot.rateLimit, isNotNull);
    });
  });

  group('thread status', () {
    test('backgroundThreadTag maps rate_limit attention to rate limited', () {
      expect(
        backgroundThreadTag(
          running: true,
          unread: true,
          attention: 'rate_limit',
          lastMessageRole: 'user',
        ),
        'rate limited',
      );
    });

    test('backgroundThreadTag rate_limit only applies while running', () {
      expect(
        backgroundThreadTag(
          running: false,
          unread: true,
          runStatus: 'completed',
          attention: 'rate_limit',
        ),
        'done',
      );
    });

    test('activeThreadTag returns rate limited while sending', () {
      expect(
        activeThreadTag(
          sending: true,
          messages: const [],
          pendingPermissionRequest: null,
          rateLimited: true,
        ),
        'rate limited',
      );
    });
  });

  group('RateLimitCountdown', () {
    RateLimitWait waitIn(Duration d) => RateLimitWait(
      retryAt: DateTime.now().add(d),
      attempt: 1,
      maxAttempts: 8,
    );

    Widget wrap(RateLimitWait w) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: RateLimitCountdown(wait: w)),
    );

    testWidgets('shows remaining seconds', (tester) async {
      await tester.pumpWidget(wrap(waitIn(const Duration(seconds: 42))));
      expect(
        find.textContaining(RegExp(r'retrying in 4[12]s')),
        findsOneWidget,
      );
    });

    testWidgets('survives periodic ticks without erroring', (tester) async {
      await tester.pumpWidget(wrap(waitIn(const Duration(seconds: 5))));
      expect(find.textContaining(RegExp(r'in [45]s')), findsOneWidget);
      // The second timer fires on the test clock while DateTime.now stays
      // real; a few ticks must not throw or blank the banner.
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('retrying in'), findsOneWidget);
    });

    testWidgets('formats minutes', (tester) async {
      await tester.pumpWidget(
        wrap(waitIn(const Duration(minutes: 2, seconds: 5))),
      );
      expect(find.textContaining(RegExp(r'in 2m [45]s')), findsOneWidget);
    });

    testWidgets('clamps a past retry time to zero', (tester) async {
      await tester.pumpWidget(
        wrap(
          RateLimitWait(
            retryAt: DateTime.now().subtract(const Duration(seconds: 3)),
            attempt: 1,
            maxAttempts: 8,
          ),
        ),
      );
      expect(find.textContaining('0s'), findsOneWidget);
    });
  });
}
