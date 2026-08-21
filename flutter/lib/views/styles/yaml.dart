import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

TextSpan highlightYaml(String code, HighlightPalette palette) {
  final spans = <TextSpan>[];
  final regex = RegExp(
      r'#.*|^\s*[\w-]+:|"(?:[^"\\]|\\.)*"|' r"'(?:[^'\\]|\\.)*'" r'|\b\d+\b|[-:]');
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('#')) return span(t, palette.comment, style: FontStyle.italic);
    if (t.endsWith(':') && !t.startsWith('"')) return span(t, palette.keyword);
    if (t.startsWith('"') || t.startsWith("'")) return span(t, palette.string);
    if (RegExp(r'^\d+$').hasMatch(t)) return span(t, palette.number);
    return span(t, palette.base);
  });
  return TextSpan(children: spans);
}
