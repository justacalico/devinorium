import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/edit_file_tool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditFileTool widget', () {
    testWidgets('renders collapsed title with filename for a single diff',
        (tester) async {
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

      expect(find.textContaining('main.rs'), findsOneWidget);
      expect(find.text('Modified'), findsOneWidget);
    });

    testWidgets('shows New file badge when old_text is null', (tester) async {
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

      expect(find.text('New file'), findsOneWidget);
    });

    testWidgets('expands to show inline diff with added and removed lines',
        (tester) async {
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.textContaining('/tmp/main.rs'), findsWidgets);
      expect(find.textContaining('- fn main() {'), findsOneWidget);
      expect(find.textContaining('-     todo!()'), findsOneWidget);
      expect(find.textContaining('+ fn main() {}'), findsOneWidget);
    });

    testWidgets('shows only new content for a new file', (tester) async {
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.textContaining('+ pub fn x() {}'), findsOneWidget);
    });

    testWidgets('shows no diff placeholder when diffs are empty',
        (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'in_progress',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.text('No diff content yet'), findsOneWidget);
    });

    testWidgets('shows count badge when multiple diffs present',
        (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit files',
        kind: 'edit',
        status: 'completed',
        diffs: [
          FileDiff(path: '/tmp/a.rs', oldText: 'a', newText: 'b'),
          FileDiff(path: '/tmp/b.rs', oldText: 'c', newText: 'd'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.text('2'), findsOneWidget);
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.text('alpha.rs'), findsWidgets);
      expect(find.text('beta.rs'), findsWidgets);

      await tester.tap(find.text('beta.rs'));
      await tester.pumpAndSettle();

      expect(find.textContaining('/tmp/beta.rs'), findsWidgets);
    });

    testWidgets('toggle to After view shows only new text', (tester) async {
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();

      expect(find.textContaining('fn main() {}'), findsOneWidget);
      expect(find.textContaining('todo!()'), findsNothing);
    });

    testWidgets('toggle to Before view shows only old text', (tester) async {
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Before'));
      await tester.pumpAndSettle();

      expect(find.textContaining('todo!()'), findsOneWidget);
      expect(find.textContaining('+ fn main() {}'), findsNothing);
    });

    testWidgets('copy button is present and tappable when expanded',
        (tester) async {
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('shows failed status icon', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Edit file',
        kind: 'edit',
        status: 'failed',
        diffs: [FileDiff(path: '/tmp/x.rs', oldText: 'a', newText: 'b')],
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: tool))),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      await tester.tap(find.text('beta.rs'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: EditFileTool(tool: second))),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('/tmp/alpha.rs'), findsWidgets);
      expect(find.text('beta.rs'), findsNothing);
    });

    testWidgets('handles Windows-style paths in title', (tester) async {
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

      expect(find.textContaining('main.rs'), findsOneWidget);
    });

    testWidgets('inline diff shows correct added and removed lines for multi-line edit',
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

      await tester.tap(find.byType(EditFileTool));
      await tester.pumpAndSettle();

      expect(find.textContaining('  line 1'), findsOneWidget);
      expect(find.textContaining('- line 2'), findsOneWidget);
      expect(find.textContaining('+ line 2 modified'), findsOneWidget);
      expect(find.textContaining('  line 3'), findsOneWidget);
      expect(find.textContaining('+ line 4'), findsOneWidget);
    });
  });
}
