import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/run_command_tool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RunCommandTool widget', () {
    testWidgets('renders command in header and output below', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        command: 'echo hello',
        output: 'world\n',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.textContaining('echo hello'), findsOneWidget);
      expect(find.textContaining('world'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });

    testWidgets('shows completed status icon', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        command: 'ls',
        output: 'file.txt',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('shows failed status icon', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'failed',
        command: 'false',
        output: 'error',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.byIcon(Icons.cancel), findsOneWidget);
    });

    testWidgets('shows pending status icon', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'pending',
        command: 'sleep 5',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    });

    testWidgets('hides output when collapsed', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        command: 'echo test',
        output: 'result line\n',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.textContaining('result line'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();

      expect(find.textContaining('result line'), findsNothing);
      expect(find.textContaining('echo test'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();

      expect(find.textContaining('result line'), findsOneWidget);
    });

    testWidgets('no collapse button when there is no output', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        command: 'true',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.textContaining('true'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('falls back to title when command is empty', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        output: 'some output',
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Run cmd'), findsOneWidget);
      expect(find.textContaining('some output'), findsOneWidget);
    });

    testWidgets('truncates very long output with scroll', (tester) async {
      final output = List.generate(100, (i) => 'line $i').join('\n');
      final tool = ToolCallData(
        id: '1',
        title: 'Run cmd',
        kind: 'execute',
        status: 'completed',
        command: 'cat big.txt',
        output: output,
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RunCommandTool(tool: tool))),
      );

      expect(find.textContaining('cat big.txt'), findsOneWidget);
      expect(find.textContaining('line 0'), findsOneWidget);
    });
  });
}
