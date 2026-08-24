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
          body: 'added 1 commit\n\n<ul><li><a href="/diffs">126cdcc5 - refactor: remove token</a></li></ul>\n\n[Compare with previous version](/compare)',
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

    testWidgets('switches to pipelines tab and lists pipelines', (tester) async {
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

    testWidgets('switches to empty pipelines tab', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pipelines (0)'));
      await tester.pumpAndSettle();

      expect(find.text('No pipelines yet.'), findsOneWidget);
    });

    testWidgets('hides action buttons when no callback is given', (tester) async {
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
  });
}
