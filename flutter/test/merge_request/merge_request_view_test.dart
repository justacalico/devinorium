import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/views/merge_request_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MergeRequestView', () {
    const detail = MergeRequestDetail(
      title: 'Add feature',
      description: '## Summary',
      state: 'opened',
      sourceBranch: 'feature',
      targetBranch: 'main',
      iid: 1,
      webUrl: 'https://gitlab.com/group/project/-/merge_requests/1',
      changes: [
        MergeRequestChange(
          oldPath: 'a.txt',
          newPath: 'a.txt',
          diff: '@@ -0,0 +1 @@\n+hello',
          newFile: true,
        ),
      ],
      comments: [
        MergeRequestComment(
          author: MergeRequestAuthor(name: 'Reviewer', username: 'reviewer'),
          body: 'Looks good',
        ),
        MergeRequestComment(
          author: MergeRequestAuthor(name: 'GitLab', username: 'GitLab'),
          body:
              'added 1 commit\n\n<ul><li><a href="/diffs">126cdcc5 - refactor: remove token</a></li></ul>\n\n[Compare with previous version](/compare)',
          system: true,
        ),
      ],
    );

    Widget wrap(AsyncValue<MergeRequestDetail> value) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MergeRequestView(detail: value, url: detail.webUrl),
      ),
    );

    testWidgets('shows loading state', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.loading()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows title and branches when ready', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      expect(find.text('Add feature'), findsOneWidget);
      expect(find.text('MR !1'), findsOneWidget);
      expect(find.text('feature → main'), findsOneWidget);
    });

    testWidgets('switches to changes tab and expands a file', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Changes (1)'));
      await tester.pumpAndSettle();

      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('@@ -0,0 +1 @@'), findsNothing);

      await tester.tap(find.text('a.txt'));
      await tester.pumpAndSettle();

      expect(find.text('+hello'), findsOneWidget);
    });

    testWidgets('switches to comments tab', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Comments (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Looks good'), findsOneWidget);
      expect(find.text('@reviewer'), findsOneWidget);
    });

    testWidgets('renders pipeline card on overview tab', (tester) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            status: 'success',
            name: 'test-and-build',
            webUrl: 'https://gitlab.com/group/project/-/pipelines/42',
            refName: 'feature',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: MergeRequestView(
              detail: AsyncValue.ready(detailWithPipeline),
              url: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('test-and-build'), findsOneWidget);
      expect(find.text('success'), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    });

    testWidgets('switches to pipelines tab and lists pipelines', (
      tester,
    ) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            status: 'failed',
            name: 'lint',
            webUrl: 'https://gitlab.com/group/project/-/pipelines/7',
          ),
          MergeRequestPipeline(
            status: 'success',
            name: 'test-and-build',
            webUrl: 'https://gitlab.com/group/project/-/pipelines/42',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: MergeRequestView(
              detail: AsyncValue.ready(detailWithPipeline),
              url: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (2)'));
      await tester.pumpAndSettle();

      expect(find.text('lint'), findsOneWidget);
      expect(find.text('test-and-build'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
      expect(find.text('success'), findsOneWidget);
    });

    testWidgets('expands a pipeline and shows its jobs', (tester) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 42,
            status: 'running',
            name: 'test-and-build',
          ),
        ],
      );

      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async => const [
        MergeRequestPipelineJob(
          id: 1,
          name: 'cargo test',
          status: 'running',
          stage: 'test',
        ),
        MergeRequestPipelineJob(
          id: 2,
          name: 'flutter test',
          status: 'success',
          stage: 'test',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();

      expect(find.text('cargo test'), findsOneWidget);
      expect(find.text('flutter test'), findsOneWidget);
    });

    testWidgets('expands a pipeline and shows empty jobs', (tester) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 42,
            status: 'success',
            name: 'test-and-build',
          ),
        ],
      );

      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async => [];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();

      expect(find.text('No jobs yet.'), findsOneWidget);
    });

    testWidgets('expands a pipeline and surfaces a job loading error', (
      tester,
    ) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 42,
            status: 'success',
            name: 'test-and-build',
          ),
        ],
      );

      var shouldFail = true;
      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async {
        if (shouldFail) throw Exception('jobs failed');
        return [];
      }

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();

      expect(find.textContaining('jobs failed'), findsOneWidget);

      shouldFail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('No jobs yet.'), findsOneWidget);
      expect(find.textContaining('jobs failed'), findsNothing);
    });

    testWidgets('does not expand a pipeline without an id', (tester) async {
      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 0,
            status: 'success',
            name: 'test-and-build',
          ),
        ],
      );

      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async => [
        const MergeRequestPipelineJob(
          id: 1,
          name: 'cargo test',
          status: 'running',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();

      expect(find.text('cargo test'), findsNothing);
    });

    testWidgets('switches to empty pipelines tab', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (0)'));
      await tester.pumpAndSettle();

      expect(find.text('No pipelines yet.'), findsOneWidget);
    });

    testWidgets('hides action buttons when no callback is given', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      expect(find.text('Merge'), findsNothing);
      expect(find.text('Close merge request'), findsNothing);
    });

    testWidgets('renders system comment HTML as markdown', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Comments (2)'));
      await tester.pumpAndSettle();

      expect(find.text('added 1 commit'), findsOneWidget);
      expect(find.text('126cdcc5 - refactor: remove token'), findsOneWidget);
      expect(find.text('Compare with previous version'), findsOneWidget);
      expect(find.text('<ul>'), findsNothing);
    });

    testWidgets('calls onJobTap when a job row is tapped', (tester) async {
      MergeRequestPipelineJob? tappedJob;

      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 42,
            status: 'running',
            name: 'test-and-build',
          ),
        ],
      );

      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async => const [
        MergeRequestPipelineJob(
          id: 1,
          name: 'cargo test',
          status: 'running',
          stage: 'test',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
              onJobTap: (job) => tappedJob = job,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cargo test'));
      await tester.pump();

      expect(tappedJob, isNotNull);
      expect(tappedJob!.id, 1);
      expect(tappedJob!.name, 'cargo test');
    });

    testWidgets('job row falls back to onLinkTap when onJobTap is null', (
      tester,
    ) async {
      String? openedUrl;

      const detailWithPipeline = MergeRequestDetail(
        title: 'Add feature',
        description: '## Summary',
        state: 'opened',
        sourceBranch: 'feature',
        targetBranch: 'main',
        iid: 1,
        webUrl: '',
        pipelines: [
          MergeRequestPipeline(
            id: 42,
            status: 'running',
            name: 'test-and-build',
          ),
        ],
      );

      Future<List<MergeRequestPipelineJob>> onLoadJobs(_) async => const [
        MergeRequestPipelineJob(
          id: 1,
          name: 'cargo test',
          status: 'running',
          stage: 'test',
          webUrl: 'https://gitlab.com/-/jobs/1',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: const AsyncValue.ready(detailWithPipeline),
              url: '',
              onLoadJobs: onLoadJobs,
              onLinkTap: (url) => openedUrl = url,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('test-and-build'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cargo test'));
      await tester.pump();

      expect(openedUrl, 'https://gitlab.com/-/jobs/1');
    });
  });
}
