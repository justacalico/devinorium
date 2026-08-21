import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

TextSpan highlightBash(String code, HighlightPalette palette) {
  final spans = <TextSpan>[];
  final regex = RegExp(
      r'#[^\n]*|"(?:[^"\\]|\\.)*"|' r"'(?:[^'\\]|\\.)*'" r'|\$\w+|\b(?:if|then|else|fi|for|while|do|done|case|esac|function|return|export|echo|cd|ls|mkdir|rm|cp|mv|cat|sudo|apt|brew|npm|cargo|flutter|dart|git)\b');
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('#')) return span(t, palette.comment, style: FontStyle.italic);
    if (t.startsWith('"') || t.startsWith("'")) return span(t, palette.string);
    if (t.startsWith(r'$')) return span(t, palette.variable);
    return span(t, palette.keyword);
  });
  return TextSpan(children: spans);
}
