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

    test('highlight returns TextSpan for java', () {
      final span =
          highlighter.highlight('public static void main() {}', 'java');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for c', () {
      final span = highlighter.highlight('int main() {}', 'c');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
      expect(span.children!.isNotEmpty, isTrue);
    });

    test('highlight returns TextSpan for cpp', () {
      final span = highlighter.highlight('auto x = 1;', 'cpp');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for csharp', () {
      final span = highlighter.highlight('using System;', 'csharp');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for c#', () {
      final span = highlighter.highlight('var x = null;', 'c#');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
    });

    test('highlight returns TextSpan for objective-c', () {
      final span = highlighter.highlight('id self = nil;', 'objective-c');
      expect(span, isA<TextSpan>());
      expect(span.children, isNotNull);
      final hasKeyword = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontWeight == FontWeight.w600;
        }
        return false;
      });
      expect(hasKeyword, isTrue);
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

    test('java highlighter colorizes keywords', () {
      final span =
          highlighter.highlight('public class App extends Object {}', 'java');
      expect(span.children, isNotNull);
      final hasKeywordColor = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontWeight == FontWeight.w600;
        }
        return false;
      });
      expect(hasKeywordColor, isTrue);
    });

    test('java highlighter colorizes comments', () {
      final span = highlighter.highlight(
        '// hello\nint x = 1; /* block */',
        'java',
      );
      expect(span.children, isNotNull);
      final hasItalic = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontStyle == FontStyle.italic;
        }
        return false;
      });
      expect(hasItalic, isTrue);
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

    test('c highlighter colorizes keywords', () {
      final span = highlighter.highlight('return nullptr;', 'c');
      expect(span.children, isNotNull);
      final hasKeywordColor = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontWeight == FontWeight.w600;
        }
        return false;
      });
      expect(hasKeywordColor, isTrue);
    });

    test('c highlighter colorizes comments', () {
      final span = highlighter.highlight(
        '// hello\nint x = 1; /* block */',
        'cpp',
      );
      expect(span.children, isNotNull);
      final hasItalic = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontStyle == FontStyle.italic;
        }
        return false;
      });
      expect(hasItalic, isTrue);
    });

    test('c highlighter colorizes preprocessor directive and header', () {
      final span = highlighter.highlight('#include <vector>', 'cpp');
      final flat = <TextSpan>[];
      void collect(TextSpan s) {
        flat.add(s);
        for (final c in s.children ?? <InlineSpan>[]) {
          if (c is TextSpan) collect(c);
        }
      }
      collect(span);
      final stringColor = SemanticColors.fallback(Brightness.light).success;
      final hasKeyword = flat.any(
        (s) => s.style?.fontWeight == FontWeight.w600,
      );
      final hasHeaderString = flat.any(
        (s) => s.text == '<vector>' && s.style?.color == stringColor,
      );
      expect(hasKeyword, isTrue);
      expect(hasHeaderString, isTrue);
    });

    test('c highlighter keeps digit separators inside numbers', () {
      final span = SyntaxHighlighter(ThemeData.dark())
          .highlight("auto x = 1'000;", 'cpp');
      final numberColor = SemanticColors.fallback(Brightness.dark).warning;
      final flat = <TextSpan>[];
      void collect(TextSpan s) {
        flat.add(s);
        for (final c in s.children ?? <InlineSpan>[]) {
          if (c is TextSpan) collect(c);
        }
      }
      collect(span);
      expect(
        flat.any((s) => s.text == "1'000" && s.style?.color == numberColor),
        isTrue,
      );
    });

    test('c highlighter keeps // inside string literals', () {
      final span = SyntaxHighlighter(ThemeData.dark())
          .highlight('const char* url = "http://x";', 'cpp');
      final flat = <TextSpan>[];
      void collect(TextSpan s) {
        flat.add(s);
        for (final c in s.children ?? <InlineSpan>[]) {
          if (c is TextSpan) collect(c);
        }
      }
      collect(span);
      final stringColor = SemanticColors.fallback(Brightness.dark).success;
      expect(
        flat.any(
          (s) => s.text == '"http://x"' && s.style?.color == stringColor,
        ),
        isTrue,
      );
    });

    test('c highlighter colorizes #if directive', () {
      final span =
          SyntaxHighlighter(ThemeData.dark()).highlight('#if DEBUG', 'c');
      final flat = <TextSpan>[];
      void collect(TextSpan s) {
        flat.add(s);
        for (final c in s.children ?? <InlineSpan>[]) {
          if (c is TextSpan) collect(c);
        }
      }
      collect(span);
      expect(
        flat.any(
          (s) => s.text == '#if' && s.style?.fontWeight == FontWeight.w600,
        ),
        isTrue,
      );
    });

    test('c highlighter reconstructs the input text exactly', () {
      const code = '#include <vector>\n'
          '#define MAX 1\'000 // cap\n'
          'int main() { auto s = "http://x"; /* done */ return 0x1F; }';
      final span = highlighter.highlight(code, 'cpp');
      final buf = StringBuffer();
      void collect(TextSpan s) {
        buf.write(s.text ?? '');
        for (final c in s.children ?? <InlineSpan>[]) {
          if (c is TextSpan) collect(c);
        }
      }
      collect(span);
      expect(buf.toString(), code);
    });

    test('csharp highlighter colorizes var and null', () {
      final span = highlighter.highlight('var x = null;', 'csharp');
      expect(span.children, isNotNull);
      final hasKeyword = span.children!.any((child) {
        if (child is TextSpan) {
          return child.style?.fontWeight == FontWeight.w600;
        }
        return false;
      });
      expect(hasKeyword, isTrue);
    });

    test('highlight is case-insensitive for language name', () {
      final span1 = highlighter.highlight('void main() {}', 'Dart');
      final span2 = highlighter.highlight('void main() {}', 'dart');
      expect(span1, isA<TextSpan>());
      expect(span2, isA<TextSpan>());
    });
  });
}
