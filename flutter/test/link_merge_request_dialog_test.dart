import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/views/sidebar/link_merge_request_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _mrUrl = 'https://gitlab.example.com/group/project/-/merge_requests/7';

Widget _buildDialog(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows the dialog with input and buttons', (tester) async {
    await tester.pumpWidget(
      _buildDialog(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => const LinkMergeRequestDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(LinkMergeRequestDialog), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Link merge request'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('cancelling the dialog returns null', (tester) async {
    String? result;
    await tester.pumpWidget(
      _buildDialog(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<String?>(
                context: context,
                builder: (_) => const LinkMergeRequestDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('saving an empty field returns null', (tester) async {
    String? result;
    await tester.pumpWidget(
      _buildDialog(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<String?>(
                context: context,
                builder: (_) => const LinkMergeRequestDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('shows an error for an invalid URL', (tester) async {
    await tester.pumpWidget(
      _buildDialog(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => const LinkMergeRequestDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid GitLab merge request URL'), findsOneWidget);
  });

  testWidgets('returns the parsed URL for a valid GitLab MR', (tester) async {
    String? result;
    await tester.pumpWidget(
      _buildDialog(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<String?>(
                context: context,
                builder: (_) => const LinkMergeRequestDialog(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _mrUrl);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, _mrUrl);
  });
}
