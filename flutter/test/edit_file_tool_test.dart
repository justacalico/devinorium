import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/edit_file_tool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditFileTool widget', () {
    testWidgets('renders file path header and inline diff directly', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(
            path: '/home/user/devinorium/src/main.rs',
            oldText: 'fn main() {\n    todo!()\n}\n',
            newText: 'fn main() {}\n',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      // File path is visible in the header (no need to expand).
      expect(find.textContaining('/home/user/devinorium/src/main.rs'), findsOneWidget);
      // Diff lines are visible directly.
      expect(find.textContaining('- fn main() {'), findsOneWidget);
      expect(find.textContaining('-     todo!()'), findsOneWidget);
      expect(find.textContaining('+ fn main() {}'), findsOneWidget);
    });

    testWidgets('shows added lines for new files', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/new.rs', newText: 'pub fn x() {}\n'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining('/tmp/new.rs'), findsOneWidget);
      expect(find.textContaining('+ pub fn x() {}'), findsOneWidget);
    });

    testWidgets('shows nothing when diffs are empty', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'in_progress',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.byType(EditFileTool), findsOneWidget);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('renders tabs for multiple diffs and switches between them',
        (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit files',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/alpha.rs', oldText: 'a', newText: 'b'),
          FileDiff(path: '/tmp/beta.rs', oldText: 'c', newText: 'd'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      // First diff is shown by default.
      expect(find.textContaining('/tmp/alpha.rs'), findsOneWidget);
      expect(find.textContaining('- a'), findsOneWidget);
      expect(find.textContaining('+ b'), findsOneWidget);

      // Tab for second file exists.
      expect(find.text('beta.rs'), findsOneWidget);

      await tester.tap(find.text('beta.rs'));
      await tester.pumpAndSettle();

      // Now second diff is shown.
      expect(find.textContaining('/tmp/beta.rs'), findsOneWidget);
      expect(find.textContaining('- c'), findsOneWidget);
      expect(find.textContaining('+ d'), findsOneWidget);
    });

    testWidgets('collapse button hides diff body', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(
            path: '/tmp/main.rs',
            oldText: 'fn main() {\n    todo!()\n}\n',
            newText: 'fn main() {}\n',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      // Diff is visible initially.
      expect(find.textContaining('- fn main() {'), findsOneWidget);

      // Tap the collapse chevron (the expand_less icon in the header).
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();

      // Diff body is hidden, but header still visible.
      expect(find.textContaining('/tmp/main.rs'), findsOneWidget);
      expect(find.textContaining('- fn main() {'), findsNothing);

      // Tap expand_more to show again.
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      expect(find.textContaining('- fn main() {'), findsOneWidget);
    });

    testWidgets('handles Windows-style paths', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(
            path: r'C:\Users\dev\src\main.rs',
            oldText: 'old',
            newText: 'new',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining(r'C:\Users\dev\src\main.rs'), findsOneWidget);
    });

    testWidgets('multi-line diff shows correct added and removed lines',
        (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(
            path: '/tmp/lib.rs',
            oldText: 'line 1\nline 2\nline 3\n',
            newText: 'line 1\nline 2 modified\nline 3\nline 4\n',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining('  line 1'), findsOneWidget);
      expect(find.textContaining('- line 2'), findsOneWidget);
      expect(find.textContaining('+ line 2 modified'), findsOneWidget);
      expect(find.textContaining('  line 3'), findsOneWidget);
      expect(find.textContaining('+ line 4'), findsOneWidget);
    });

    testWidgets('copy button is present in header', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/main.rs', oldText: 'old', newText: 'new body'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('clamps selected diff index when diffs shrink', (tester) async {
      final first = ToolCallData(
        id: '1',
        title: 'Edit files',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/alpha.rs', oldText: 'a', newText: 'b'),
          FileDiff(path: '/tmp/beta.rs', oldText: 'c', newText: 'd'),
        ],
      );
      final second = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/alpha.rs', oldText: 'a', newText: 'b'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: first))),
      );

      // Switch to second diff tab.
      await tester.tap(find.text('beta.rs'));
      await tester.pumpAndSettle();

      // Replace with single diff.
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: second))),
      );
      await tester.pumpAndSettle();

      // Alpha is shown, beta tab is gone.
      expect(find.textContaining('/tmp/alpha.rs'), findsOneWidget);
      expect(find.text('beta.rs'), findsNothing);
    });

    testWidgets('shows new file icon for new files', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/new.rs', newText: 'pub fn x() {}\n'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });

    testWidgets('shows edit icon for modified files', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/main.rs', oldText: 'old', newText: 'new'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    });

    testWidgets('shows no diff message when old and new text are identical',
        (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/main.rs', oldText: 'same', newText: 'same'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining('/tmp/main.rs'), findsOneWidget);
      // Context line is shown (no +/- changes).
      expect(find.textContaining('  same'), findsOneWidget);
    });

    testWidgets('handles empty new text', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/main.rs', oldText: 'old content', newText: ''),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining('/tmp/main.rs'), findsOneWidget);
      // Old line is shown as removed.
      expect(find.textContaining('- old content'), findsOneWidget);
    });

    testWidgets('onOpenInFiles callback shows button and fires when tapped',
        (tester) async {
      var opened = false;
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/main.rs', oldText: 'old', newText: 'new'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditFileTool(
              tool: tool,
              onOpenInFiles: () => opened = true,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.open_in_new), findsOneWidget);

      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();

      expect(opened, isTrue);
    });

    testWidgets('truncates very large diffs with a note', (tester) async {
      final oldText = List.generate(600, (i) => 'old line $i').join('\n');
      final newText = List.generate(600, (i) => 'new line $i').join('\n');

      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/big.rs', oldText: oldText, newText: newText),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.textContaining('/tmp/big.rs'), findsOneWidget);
      // Truncation note is shown.
      expect(find.textContaining('more lines not shown'), findsOneWidget);
    });

    testWidgets('caches diff computation across rebuilds', (tester) async {
      final diff = FileDiff(
        path: '/tmp/main.rs',
        oldText: 'fn main() {\n    todo!()\n}\n',
        newText: 'fn main() {}\n',
      );
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'completed',
        diffs: [diff],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      // Trigger a rebuild by toggling collapse.
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      // Diff content is still correct after rebuild (cache hit).
      expect(find.textContaining('- fn main() {'), findsOneWidget);
      expect(find.textContaining('+ fn main() {}'), findsOneWidget);
    });
  });
}
