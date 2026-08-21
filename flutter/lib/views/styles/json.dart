import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

/// Highlights JSON code: keys, string values, booleans, null, numbers,
/// and structural punctuation.
TextSpan highlightJson(String code, HighlightPalette palette) {
  final spans = <TextSpan>[];
  final regex = RegExp(
    r'"(?:[^"\\]|\\.)*"\s*:|"(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\d+\.?\d*([eE][+-]?\d+)?|[{}\[\],:]',
  );
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.endsWith(':')) {
      return span(t, palette.keyword);
    } else if (t.startsWith('"')) {
      return span(t, palette.string);
    } else if (t == 'true' || t == 'false' || t == 'null') {
      return span(t, palette.number);
    } else if (RegExp(r'^-?\d').hasMatch(t)) {
      return span(t, palette.number);
    } else if (RegExp(r'^[{}\[\],:]$').hasMatch(t)) {
      return span(t, palette.variable);
    }
    return span(t, palette.base);
  });
  return TextSpan(children: spans);
}
