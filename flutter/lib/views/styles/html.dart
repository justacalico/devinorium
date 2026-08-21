import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

TextSpan highlightHtml(String code, HighlightPalette palette) {
  final spans = <TextSpan>[];
  final regex = RegExp(r'<!--[\s\S]*?-->|<\/?\w+[^>]*>|[^<]+');
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('<!--')) return span(t, palette.comment, style: FontStyle.italic);
    if (t.startsWith('<')) {
      final tagRegex = RegExp(r'<\/?(\w+)|(\w+)=|("[^"]*")|(' r"'[^']*'" r')|>');
      final tagSpans = <TextSpan>[];
      tokenize(t, tagRegex, tagSpans, palette, (m) {
        final mt = m[0]!;
        if (mt.startsWith('</') || mt.startsWith('<')) return span(mt, palette.keyword);
        if (mt.endsWith('=')) return span(mt, palette.variable);
        if (mt.startsWith('"') || mt.startsWith("'")) return span(mt, palette.string);
        if (mt == '>') return span(mt, palette.keyword);
        return span(mt, palette.function);
      });
      return TextSpan(children: tagSpans);
    }
    return span(t, palette.base);
  });
  return TextSpan(children: spans);
}
