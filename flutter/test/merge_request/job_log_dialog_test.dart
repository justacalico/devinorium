import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:devinorium_frontend/views/job_log_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JobLogDialog', () {
    const job = MergeRequestPipelineJob(
      id: 101,
      name: 'cargo test',
      status: 'running',
      stage: 'test',
    );

    Widget buildDialog({
      required Future<JobLog> Function() onLoad,
      Duration pollInterval = const Duration(seconds: 1),
    }) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: JobLogDialog(
        job: job,
        onLoad: onLoad,
        pollInterval: pollInterval,
      ),
    );

    testWidgets('displays the job name and trace', (tester) async {
      await tester.pumpWidget(
        buildDialog(
          onLoad: () async => const JobLog(
            job: MergeRequestPipelineJob(
              id: 101,
              name: 'cargo test',
              status: 'success',
              stage: 'test',
            ),
            trace: 'build complete',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('cargo test'), findsOneWidget);
      expect(find.text('build complete'), findsOneWidget);
    });

    testWidgets('stops polling when the job finishes', (tester) async {
      var calls = 0;
      final logs = [
        const JobLog(
          job: MergeRequestPipelineJob(
            id: 101,
            name: 'cargo test',
            status: 'running',
            stage: 'test',
          ),
          trace: 'first',
        ),
        const JobLog(
          job: MergeRequestPipelineJob(
            id: 101,
            name: 'cargo test',
            status: 'success',
            stage: 'test',
          ),
          trace: 'second',
        ),
      ];

      await tester.pumpWidget(
        buildDialog(
          onLoad: () async => logs[calls++],
          pollInterval: const Duration(seconds: 1),
        ),
      );
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('shows an error and retry when the initial load fails', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        buildDialog(
          onLoad: () async {
            calls++;
            if (calls == 1) throw Exception('network down');
            return const JobLog(
              job: MergeRequestPipelineJob(
                id: 101,
                name: 'cargo test',
                status: 'success',
                stage: 'test',
              ),
              trace: 'recovered',
            );
          },
        ),
      );
      await tester.pump();

      expect(find.textContaining('network down'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(find.text('recovered'), findsOneWidget);
      expect(find.textContaining('network down'), findsNothing);
    });

    testWidgets('keeps the existing log when a poll fails', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        buildDialog(
          onLoad: () async {
            calls++;
            if (calls == 1) {
              return const JobLog(
                job: MergeRequestPipelineJob(
                  id: 101,
                  name: 'cargo test',
                  status: 'running',
                  stage: 'test',
                ),
                trace: 'first',
              );
            }
            throw Exception('poll failed');
          },
          pollInterval: const Duration(seconds: 1),
        ),
      );
      await tester.pump();

      expect(find.text('first'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(find.textContaining('poll failed'), findsOneWidget);
    });

    testWidgets('cancels the polling timer when disposed', (tester) async {
      var calls = 0;

      await tester.pumpWidget(
        buildDialog(
          onLoad: () async {
            calls++;
            return const JobLog(
              job: MergeRequestPipelineJob(
                id: 101,
                name: 'cargo test',
                status: 'running',
                stage: 'test',
              ),
              trace: 'trace',
            );
          },
          pollInterval: const Duration(milliseconds: 100),
        ),
      );
      await tester.pump();
      expect(calls, 1);

      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, greaterThan(1));

      final beforeDispose = calls;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, beforeDispose);
    });
  });
}
