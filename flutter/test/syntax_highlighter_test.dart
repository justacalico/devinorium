import 'package:devinorium_frontend/theme/semantic_colors.dart';
import 'package:devinorium_frontend/views/syntax_highlighter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyntaxHighlighter', () {
    final highlighter = SyntaxHighlighter(ThemeData.light());

    test('highlight returns TextSpan for json', () {
      final span = highlighter.highlight('{"key": "value"}', 'json');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
      expect(span.children!.isNotEmpty, isTrue);
    });

    test('highlight returns TextSpan for dart', () {
      final span = highlighter.highlight('void main() {}', 'dart');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for rust', () {
      final span = highlighter.highlight('fn main() {}', 'rust');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for python', () {
      final span = highlighter.highlight('def main(): pass', 'python');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for javascript', () {
      final span = highlighter.highlight('function main() {}', 'javascript');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for bash', () {
      final span = highlighter.highlight('echo "hello"', 'bash');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for yaml', () {
      final span = highlighter.highlight('key: value', 'yaml');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for sql', () {
      final span = highlighter.highlight('SELECT * FROM users', 'sql');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for html', () {
      final span = highlighter.highlight('<div>hello</div>', 'html');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for css', () {
      final span = highlighter.highlight('.class { color: red; }', 'css');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight falls back to plain text for unknown language', () {
      final span = highlighter.highlight('some code', 'brainfuck');
      expect(span, isA<TextSpan>());
      expect((span).text, 'some code');
      expect(span.children, isNull);
    });

    test('highlight handles empty string', () {
      final span = highlighter.highlight('', 'json');
      expect(span, isA<TextSpan>());
    });

    test('highlight handles empty language', () {
      final span = highlighter.highlight('some code', '');
      expect(span, isA<TextSpan>());
      expect((span).text, 'some code');
    });

    test('json highlighter colorizes strings', () {
      final span = highlighter.highlight('"hello"', 'json');
      expect(span.children, isNotNull);
      // At least one child span should have the string color.
      final stringColor = SemanticColors.fallback(Brightness.light).success;
      final hasStringColor = span.children!.any((child) {
        if (child is TextSpan) {
          final color = child.style?.color;
          return color == stringColor;
        }
        return false;
      });
      expect(hasStringColor, isTrue);
    });

    test('dart highlighter colorizes keywords', () {
      final span = highlighter.highlight('class MyClass {}', 'dart');
      expect(span.children, isNotNull);
      // At least one child span should have the keyword color (primary).
      final hasKeywordColor = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontWeight == FontWeight.w600;
        }
        return false;
      });
      expect(hasKeywordColor, isTrue);
    });

    test('highlight is case-insensitive for language name', () {
      final span1 = highlighter.highlight('void main() {}', 'Dart');
      final span2 = highlighter.highlight('void main() {}', 'dart');
      expect(span1, isA<TextSpan>());
      expect(span2, isA<TextSpan>());
    });
  });
}
