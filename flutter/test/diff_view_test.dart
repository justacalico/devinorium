import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiffView', () {
    testWidgets('renders all lines as added for new files', (tester) async {
      final diff = FileDiff(
        path: '/x.dart',
        oldText: null,
        newText: 'line one\nline two\n',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DiffView(diff: diff)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('+ line one'), findsOneWidget);
      expect(find.textContaining('+ line two'), findsOneWidget);
    });

    testWidgets('renders removed and added lines with context', (tester) async {
      final diff = FileDiff(
        path: '/x.dart',
        oldText: 'alpha\nbeta\ngamma\n',
        newText: 'alpha\nBETA\ngamma\n',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DiffView(diff: diff)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('- beta'), findsOneWidget);
      expect(find.textContaining('+ BETA'), findsOneWidget);
      expect(find.textContaining('  alpha'), findsOneWidget);
      expect(find.textContaining('  gamma'), findsOneWidget);
    });

    testWidgets('shows no diff message for identical content', (tester) async {
      final diff = FileDiff(
        path: '/x.dart',
        oldText: 'same',
        newText: 'same',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DiffView(diff: diff)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('No diff content yet'), findsOneWidget);
    });

    testWidgets('truncates very large diffs with a note', (tester) async {
      final newText = List.generate(600, (i) => 'line $i').join('\n');
      final oldText = List.generate(600, (i) => 'old $i').join('\n');
      final diff = FileDiff(
        path: '/x.dart',
        oldText: oldText,
        newText: newText,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiffView(diff: diff),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('more lines not shown'), findsOneWidget);
    });

    testWidgets('renders empty new files without crashing', (tester) async {
      final diff = FileDiff(
        path: '/x.dart',
        oldText: null,
        newText: '',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DiffView(diff: diff)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DiffView), findsOneWidget);
      expect(find.textContaining('No diff content yet'), findsOneWidget);
    });

    testWidgets('respects maxHeight when provided', (tester) async {
      final diff = FileDiff(
        path: '/x.dart',
        oldText: null,
        newText: 'one\ntwo\n',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiffView(diff: diff, maxHeight: 400),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final finder = find.byWidgetPredicate(
        (w) => w is ConstrainedBox && w.constraints.maxHeight == 400,
      );
      expect(finder, findsOneWidget);
    });
  });
}
