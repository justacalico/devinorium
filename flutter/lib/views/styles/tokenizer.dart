import 'package:flutter/material.dart';

import 'palette.dart';

/// Creates a [TextSpan] with monospace font and the given color.
TextSpan span(String text, Color color,
    {FontStyle? style, FontWeight? weight}) {
  return TextSpan(
    text: text,
    style: TextStyle(
      color: color,
      fontFamily: 'monospace',
      fontStyle: style,
      fontWeight: weight,
    ),
  );
}

/// Splits [code] by [regex] matches, calling [onMatch] for each match and
/// filling gaps with plain base-colored spans.
void tokenize(
  String code,
  RegExp regex,
  List<TextSpan> spans,
  HighlightPalette palette,
  TextSpan Function(Match) onMatch,
) {
  var lastEnd = 0;
  for (final match in regex.allMatches(code)) {
    if (match.start > lastEnd) {
      spans.add(span(code.substring(lastEnd, match.start), palette.base));
    }
    spans.add(onMatch(match));
    lastEnd = match.end;
  }
  if (lastEnd < code.length) {
    spans.add(span(code.substring(lastEnd), palette.base));
  }
}
