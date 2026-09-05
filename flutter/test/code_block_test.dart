import 'package:devinorium_frontend/views/code_block.dart';
import 'package:devinorium_frontend/views/syntax_highlighter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingHighlighter extends SyntaxHighlighter {
  int callCount = 0;

  _CountingHighlighter(super.theme);

  @override
  TextSpan highlight(String code, String language) {
    callCount++;
    return super.highlight(code, language);
  }
}

void main() {
  group('CodeBlock', () {
    testWidgets('renders code text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
            ),
          ),
        ),
      );

      expect(find.text('print("hello")'), findsOneWidget);
    });

    testWidgets('shows language label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'fn main() {}',
              language: 'rust',
            ),
          ),
        ),
      );

      expect(find.text('rust'), findsOneWidget);
    });

    testWidgets('shows text label when no language', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'plain text',
            ),
          ),
        ),
      );

      expect(find.text('text'), findsOneWidget);
    });

    testWidgets('shows copy button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'x = 1',
              language: 'python',
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('copy button swaps label to Copied then reverts', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'hello world',
              language: 'text',
            ),
          ),
        ),
      );

      expect(find.text('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pumpAndSettle();

      expect(find.text('Copied'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsNothing);

      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('Copy'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('caches highlighted span across rebuilds', (tester) async {
      final highlighter = _CountingHighlighter(ThemeData.light());
      const code = 'print("hello")';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: code,
              language: 'python',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: code,
              language: 'python',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 1);
    });

    testWidgets('re-highlights when code changes', (tester) async {
      final highlighter = _CountingHighlighter(ThemeData.light());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("world")',
              language: 'python',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 2);
    });

    testWidgets('re-highlights when language changes', (tester) async {
      final highlighter = _CountingHighlighter(ThemeData.light());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'javascript',
              highlighter: highlighter,
            ),
          ),
        ),
      );

      expect(highlighter.callCount, 2);
    });

    testWidgets('re-highlights when highlighter changes', (tester) async {
      final highlighter1 = _CountingHighlighter(ThemeData.light());
      final highlighter2 = _CountingHighlighter(ThemeData.light());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
              highlighter: highlighter1,
            ),
          ),
        ),
      );

      expect(highlighter1.callCount, 1);
      expect(highlighter2.callCount, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
              highlighter: highlighter2,
            ),
          ),
        ),
      );

      expect(highlighter1.callCount, 1);
      expect(highlighter2.callCount, 1);
    });

    testWidgets('re-highlights when highlighter is recreated on a theme change', (tester) async {
      var callCount = 0;

      Widget buildWithTheme(ThemeData theme) {
        return MaterialApp(
          theme: theme,
          home: Scaffold(
            body: CodeBlock(
              code: 'print("hello")',
              language: 'python',
              highlighter: _CountingHighlighter(theme)..callCount = callCount,
            ),
          ),
        );
      }

      final theme1 = ThemeData.light();
      final theme2 = ThemeData.dark();

      await tester.pumpWidget(buildWithTheme(theme1));

      final highlighter = tester.widget<CodeBlock>(find.byType(CodeBlock)).highlighter
          as _CountingHighlighter;
      callCount = highlighter.callCount;
      expect(callCount, 1);

      await tester.pumpWidget(buildWithTheme(theme2));

      final highlighter2 = tester.widget<CodeBlock>(find.byType(CodeBlock)).highlighter
          as _CountingHighlighter;
      expect(highlighter2, isNot(same(highlighter)));
      expect(highlighter2.callCount, 2);
    });
  });
}
