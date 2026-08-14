import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/views/read_file_tool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseReadTool', () {
    test('parses file_path and counts output lines', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/home/user/devinorium/pubspec.yaml"}',
        output: 'name: devinorium_frontend\ndescription: test\n',
      );

      final info = parseReadTool(tool)!;

      expect(info.filePath, '/home/user/devinorium/pubspec.yaml');
      expect(info.fileName, 'pubspec.yaml');
      expect(info.lineCount, 2);
      expect(info.lines, hasLength(2));
      expect(info.content, 'name: devinorium_frontend\ndescription: test\n');
    });

    test('ignores a single trailing newline', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/file.txt"}',
        output: 'line one\nline two\nline three\n',
      );

      final info = parseReadTool(tool)!;
      expect(info.lineCount, 3);
      expect(info.lines, hasLength(3));
    });

    test('counts intentional blank lines', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/file.txt"}',
        output: 'line one\n\nline three\n',
      );

      final info = parseReadTool(tool)!;
      expect(info.lineCount, 3);
      expect(info.lines, hasLength(3));
    });

    test('handles empty output', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/empty.txt"}',
        output: '',
      );

      final info = parseReadTool(tool)!;
      expect(info.lineCount, 0);
      expect(info.lines, isEmpty);
    });

    test('parses start_line and end_line', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/etc/hosts","start_line":10,"end_line":20}',
        output: '',
      );

      final info = parseReadTool(tool)!;

      expect(info.startLine, 10);
      expect(info.endLine, 20);
      expect(info.lineCount, 0);
    });

    test('returns null for non-read kind', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Run command',
        kind: 'execute',
        status: 'completed',
        command: 'ls',
      );

      expect(parseReadTool(tool), isNull);
    });

    test('returns null when command is missing', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
      );

      expect(parseReadTool(tool), isNull);
    });

    test('falls back to raw command as path when json is invalid', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '/var/log/syslog',
        output: 'line one',
      );

      final info = parseReadTool(tool)!;
      expect(info.filePath, '/var/log/syslog');
      expect(info.fileName, 'syslog');
      expect(info.lineCount, 1);
    });

    test('parses Windows-style paths', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"C:\\\\Users\\\\devinorium\\\\file.txt"}',
        output: 'content',
      );

      final info = parseReadTool(tool)!;
      expect(info.fileName, 'file.txt');
    });

    test('extracts line count from output preview when output is empty', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/big.sql"}',
        outputPreview: '89 lines',
      );

      final info = parseReadTool(tool)!;
      expect(info.fileName, 'big.sql');
      expect(info.lineCount, 89);
    });

    test('extracts line count case-insensitively', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/big.sql"}',
        outputPreview: '89 Lines',
      );

      final info = parseReadTool(tool)!;
      expect(info.lineCount, 89);
    });

    test('extracts zero line count', () {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/empty.sql"}',
        outputPreview: '0 lines',
      );

      final info = parseReadTool(tool)!;
      expect(info.lineCount, 0);
    });
  });

  group('ReadFileTool widget', () {
    testWidgets('renders collapsed title with filename and line count', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/home/calico/devinorium/migrations/0001_init.sql"}',
        output: 'CREATE TABLE users\n(\n  id INTEGER\n);\n',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadFileTool(tool: tool),
          ),
        ),
      );

      expect(find.textContaining('0001_init.sql'), findsOneWidget);
      expect(find.text('4 lines'), findsOneWidget);
    });

    testWidgets('expands to show code block with line numbers', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/home/calico/devinorium/migrations/0001_init.sql"}',
        output: 'CREATE TABLE users\n(\n  id INTEGER\n);\n',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadFileTool(tool: tool),
          ),
        ),
      );

      await tester.tap(find.byType(ReadFileTool));
      await tester.pumpAndSettle();

      expect(find.text('CREATE TABLE users\n(\n  id INTEGER\n);'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('shows no content placeholder when output is empty', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/home/calico/devinorium/migrations/0001_init.sql"}',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadFileTool(tool: tool),
          ),
        ),
      );

      await tester.tap(find.byType(ReadFileTool));
      await tester.pumpAndSettle();

      expect(find.text('No content'), findsOneWidget);
    });

    testWidgets('shows failed status', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'failed',
        command: '{"file_path":"/missing.txt"}',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadFileTool(tool: tool),
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('re-parses when tool data changes', (tester) async {
      final first = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/a.txt"}',
        output: 'first\n',
      );
      final second = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/b.txt"}',
        output: 'first\nsecond\n',
      );

      late StateSetter setState;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setter) {
                setState = setter;
                return ReadFileTool(tool: first);
              },
            ),
          ),
        ),
      );

      expect(find.textContaining('a.txt'), findsOneWidget);
      expect(find.text('1 line'), findsOneWidget);

      setState(() {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setter) {
                setState = setter;
                return ReadFileTool(tool: second);
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.textContaining('b.txt'), findsOneWidget);
      expect(find.text('2 lines'), findsOneWidget);
    });

    testWidgets('constrains expanded code block height', (tester) async {
      final tool = ToolCallData(
        id: '1',
        title: 'Read file',
        kind: 'read',
        status: 'completed',
        command: '{"file_path":"/tmp/big.txt"}',
        output: List.generate(1000, (i) => 'line $i').join('\n'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadFileTool(tool: tool),
          ),
        ),
      );

      await tester.tap(find.byType(ReadFileTool));
      await tester.pumpAndSettle();

      final finder = find.descendant(
        of: find.byType(ReadFileTool),
        matching: find.byWidgetPredicate(
          (w) => w is ConstrainedBox && w.constraints.maxHeight == 300,
        ),
      );
      expect(finder, findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });
}
