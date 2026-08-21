import 'package:devinorium_frontend/views/elapsed_time_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ElapsedTimeIndicator', () {
    testWidgets('shows nothing when not active', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: DateTime.now().toUtc().toIso8601String(),
              active: false,
            ),
          ),
        ),
      );

      expect(find.byType(ElapsedTimeIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows nothing when startedAt is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(startedAt: null, active: true),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows nothing when startedAt is invalid', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(startedAt: 'not-a-date', active: true),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows elapsed seconds when active', (tester) async {
      final startedAt = DateTime.now().toUtc().toIso8601String();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: startedAt,
              active: true,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('s'), findsOneWidget);
    });

    testWidgets('shows minutes format after 60 seconds', (tester) async {
      final start = DateTime.now().toUtc().subtract(const Duration(seconds: 90));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: start.toIso8601String(),
              active: true,
            ),
          ),
        ),
      );

      expect(find.textContaining('m'), findsOneWidget);
    });

    testWidgets('shows hours format after 60 minutes', (tester) async {
      final start =
          DateTime.now().toUtc().subtract(const Duration(minutes: 75));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: start.toIso8601String(),
              active: true,
            ),
          ),
        ),
      );

      expect(find.textContaining('h'), findsOneWidget);
    });

    testWidgets('shows correct elapsed time from startedAt', (tester) async {
      final start =
          DateTime.now().toUtc().subtract(const Duration(seconds: 5));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: start.toIso8601String(),
              active: true,
            ),
          ),
        ),
      );

      // Should show approximately 5s.
      expect(find.text('5s'), findsOneWidget);
    });

    testWidgets('stops timer when active becomes false', (tester) async {
      final start = DateTime.now().toUtc();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: start.toIso8601String(),
              active: true,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElapsedTimeIndicator(
              startedAt: start.toIso8601String(),
              active: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
