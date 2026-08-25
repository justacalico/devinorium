import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/issue/issue_models.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/views/issue_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IssueView', () {
    const detail = IssueDetail(
      title: 'Bug in login',
      description: '## Steps\n\n1. Open the app',
      state: 'opened',
      iid: 1,
      webUrl: 'https://gitlab.com/group/project/-/issues/1',
      author: MergeRequestAuthor(name: 'Dev', username: 'dev'),
      createdAt: '2026-01-01T00:00:00Z',
      labels: ['bug', 'frontend'],
      milestone: 'v1.0',
      assignees: [
        MergeRequestAuthor(name: 'Alice', username: 'alice'),
      ],
      comments: [
        MergeRequestComment(
          author: MergeRequestAuthor(name: 'Reviewer', username: 'reviewer'),
          body: 'Confirmed',
        ),
        MergeRequestComment(
          author: MergeRequestAuthor(name: 'GitLab', username: 'GitLab'),
          body: 'closed\n\n<a href="/x">commit abc</a>',
          system: true,
        ),
      ],
    );

    Widget wrap(AsyncValue<IssueDetail> value) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: IssueView(detail: value, url: detail.webUrl)),
        );

    testWidgets('shows loading state', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.loading()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows title and iid when ready', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      expect(find.text('Bug in login'), findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('@dev'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('shows labels and milestone on overview tab', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      expect(find.text('bug'), findsOneWidget);
      expect(find.text('frontend'), findsOneWidget);
      expect(find.textContaining('milestone: v1.0'), findsOneWidget);
      expect(find.textContaining('assigned to @alice'), findsOneWidget);
    });

    testWidgets('switches to comments tab and renders comments', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Comments (2)'));
      await tester.pumpAndSettle();

      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('@reviewer'), findsOneWidget);
    });

    testWidgets('renders system comment HTML as markdown', (tester) async {
      await tester.pumpWidget(wrap(const AsyncValue.ready(detail)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Comments (2)'));
      await tester.pumpAndSettle();

      expect(find.text('closed'), findsOneWidget);
      expect(find.text('commit abc'), findsOneWidget);
      expect(find.text('<a href="/x">'), findsNothing);
    });

    testWidgets('shows no-description placeholder', (tester) async {
      const noDesc = IssueDetail(
        title: 'Empty',
        description: '',
        state: 'opened',
        iid: 2,
        webUrl: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: IssueView(detail: AsyncValue.ready(noDesc), url: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No description provided.'), findsOneWidget);
    });

    testWidgets('shows error and retry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: IssueView(
              detail: const AsyncValue.error('boom'),
              onRetry: () => retries++,
            ),
          ),
        ),
      );

      expect(find.text('boom'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });

    testWidgets('shows closed badge for a closed issue', (tester) async {
      const closed = IssueDetail(
        title: 'Done',
        state: 'closed',
        iid: 3,
        webUrl: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: IssueView(detail: AsyncValue.ready(closed), url: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Closed'), findsOneWidget);
    });
  });
}
