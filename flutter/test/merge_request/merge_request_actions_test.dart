import 'dart:async';

import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/views/merge_request_action_bar.dart';
import 'package:devinorium_frontend/views/merge_request_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MergeRequestDetail _detail({
  String state = 'opened',
  bool draft = false,
  bool hasConflicts = false,
  bool mergeWhenPipelineSucceeds = false,
  List<MergeRequestPipeline> pipelines = const [],
}) =>
    MergeRequestDetail(
      title: 'Add feature',
      state: state,
      sourceBranch: 'feature',
      targetBranch: 'main',
      iid: 1,
      webUrl: '',
      draft: draft,
      hasConflicts: hasConflicts,
      mergeWhenPipelineSucceeds: mergeWhenPipelineSucceeds,
      pipelines: pipelines,
    );

void main() {
  group('MergeRequestView actions', () {
    final performed = <MergeRequestAction>[];
    Object? failWith;

    setUp(() {
      performed.clear();
      failWith = null;
    });

    Widget wrap(MergeRequestDetail detail) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MergeRequestView(
              detail: AsyncValue.ready(detail),
              url: '',
              onAction: (action) async {
                performed.add(action);
                if (failWith != null) throw failWith!;
              },
            ),
          ),
        );

    testWidgets('merges an open merge request', (tester) async {
      await tester.pumpWidget(wrap(_detail()));
      await tester.pumpAndSettle();

      expect(find.text('Merge when pipeline succeeds'), findsNothing);

      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(performed, [MergeRequestAction.merge]);
    });

    testWidgets('closes an open merge request', (tester) async {
      await tester.pumpWidget(wrap(_detail()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Close merge request'));
      await tester.pumpAndSettle();

      expect(performed, [MergeRequestAction.close]);
    });

    testWidgets('reopens a closed merge request', (tester) async {
      await tester.pumpWidget(wrap(_detail(state: 'closed')));
      await tester.pumpAndSettle();

      expect(find.text('Merge'), findsNothing);
      expect(find.text('Close merge request'), findsNothing);

      await tester.tap(find.text('Reopen merge request'));
      await tester.pumpAndSettle();

      expect(performed, [MergeRequestAction.reopen]);
    });

    testWidgets('offers auto merge while a pipeline is running', (tester) async {
      await tester.pumpWidget(wrap(_detail(
        pipelines: const [MergeRequestPipeline(status: 'running')],
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge when pipeline succeeds'));
      await tester.pumpAndSettle();

      expect(performed, [MergeRequestAction.mergeWhenPipelineSucceeds]);
    });

    testWidgets('hides merge and offers cancel once auto merge is set',
        (tester) async {
      await tester.pumpWidget(wrap(_detail(
        mergeWhenPipelineSucceeds: true,
        pipelines: const [MergeRequestPipeline(status: 'running')],
      )));
      await tester.pumpAndSettle();

      expect(find.text('Merge'), findsNothing);
      expect(find.text('Merge when pipeline succeeds'), findsNothing);
      expect(find.text('Cancel auto merge'), findsOneWidget);
      expect(
        find.text('This merge request will merge once the pipeline succeeds.'),
        findsOneWidget,
      );
    });

    testWidgets('cancels an auto merge', (tester) async {
      await tester.pumpWidget(wrap(_detail(
        mergeWhenPipelineSucceeds: true,
        pipelines: const [MergeRequestPipeline(status: 'running')],
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel auto merge'));
      await tester.pumpAndSettle();

      expect(performed, [MergeRequestAction.cancelAutoMerge]);
    });

    testWidgets('blocks merging drafts', (tester) async {
      await tester.pumpWidget(wrap(_detail(draft: true)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(performed, isEmpty);
      expect(
        find.text('Mark the merge request ready before merging.'),
        findsOneWidget,
      );
    });

    testWidgets('blocks merging with conflicts', (tester) async {
      await tester.pumpWidget(wrap(_detail(hasConflicts: true)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(performed, isEmpty);
      expect(find.text('Resolve the conflicts before merging.'), findsOneWidget);
    });

    testWidgets('shows no actions for a merged merge request', (tester) async {
      await tester.pumpWidget(wrap(_detail(state: 'merged')));
      await tester.pumpAndSettle();

      expect(find.text('Merge'), findsNothing);
      expect(find.text('Close merge request'), findsNothing);
      expect(find.text('Reopen merge request'), findsNothing);
    });

    testWidgets('disables the buttons while an action is in flight',
        (tester) async {
      final gate = Completer<void>();

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MergeRequestView(
            detail: AsyncValue.ready(_detail()),
            url: '',
            onAction: (action) async {
              performed.add(action);
              await gate.future;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Merge')).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Close merge request'))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Close merge request'));
      await tester.pump();
      expect(performed, [MergeRequestAction.merge]);

      final disabledClose = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Close merge request'),
      );
      final disabledFg = disabledClose.style?.foregroundColor
          ?.resolve({WidgetState.disabled});
      final enabledFg = disabledClose.style?.foregroundColor
          ?.resolve(<WidgetState>{});
      expect(disabledFg, isNot(equals(enabledFg)));

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('survives being unmounted mid action', (tester) async {
      final gate = Completer<void>();

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MergeRequestView(
            detail: AsyncValue.ready(_detail()),
            url: '',
            onAction: (action) async {
              performed.add(action);
              await gate.future;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge'));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the failure and keeps the merge request', (tester) async {
      failWith = 'Method Not Allowed';

      await tester.pumpWidget(wrap(_detail()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(find.text('Method Not Allowed'), findsOneWidget);
      expect(find.text('Add feature'), findsOneWidget);
    });

    testWidgets('groups compact macOS-style buttons tightly together',
        (tester) async {
      await tester.pumpWidget(wrap(_detail()));
      await tester.pumpAndSettle();

      final bar = tester.widget<Wrap>(
        find.descendant(
          of: find.byType(MergeRequestActionBar),
          matching: find.byType(Wrap),
        ),
      );
      expect(bar.spacing, 6);
      expect(bar.runSpacing, 6);

      final merge = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Merge'),
      );
      final mergeShape = merge.style?.shape?.resolve({});
      expect(mergeShape, isA<RoundedRectangleBorder>());
      expect(
        (mergeShape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(7),
      );

      final close = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Close merge request'),
      );
      expect(close.style?.minimumSize?.resolve({})?.height, 30);
      expect(close.style?.shape?.resolve({}), isA<RoundedRectangleBorder>());
    });
  });
}
