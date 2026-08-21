import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

/// Generic highlighter for C-style languages. Colorizes comments, strings,
/// numbers, keywords, types, and capitalized identifiers.
TextSpan highlightGeneric(
  String code,
  HighlightPalette palette, {
  required Set<String> keywords,
  required Set<String> types,
}) {
  final spans = <TextSpan>[];
  final regex = RegExp(
    r'//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|'
        r"'(?:[^'\\]|\\.)*'"
        r'|`(?:[^`\\]|\\.)*`|\b\d+\.?\d*\b|\b[A-Z]\w*\b|\b\w+\b|[^\s\w]',
  );
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('//') || t.startsWith('#') || t.startsWith('/*')) {
      return span(t, palette.comment, style: FontStyle.italic);
    }
    if (t.startsWith('"') || t.startsWith("'") || t.startsWith('`')) {
      return span(t, palette.string);
    }
    if (RegExp(r'^\d').hasMatch(t)) {
      return span(t, palette.number);
    }
    if (keywords.contains(t)) {
      return span(t, palette.keyword, weight: FontWeight.w600);
    }
    if (types.contains(t)) {
      return span(t, palette.type);
    }
    if (RegExp(r'^[A-Z]').hasMatch(t)) {
      return span(t, palette.type);
    }
    return span(t, palette.base);
  });
  return TextSpan(children: spans);
}
