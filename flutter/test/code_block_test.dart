import 'package:devinorium_frontend/views/code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CodeBlock', () {
    testWidgets('renders code text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
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
        MaterialApp(
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
        MaterialApp(
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
        MaterialApp(
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

    testWidgets('copy button copies to clipboard', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeBlock(
              code: 'hello world',
              language: 'text',
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pumpAndSettle();

      // Verify snackbar appears.
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });
  });
}
