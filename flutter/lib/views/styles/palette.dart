import 'package:flutter/material.dart';

import '../../theme/semantic_colors.dart';

/// Color palette for syntax highlighting. Shared across all language
/// highlighters so the look stays consistent.
class HighlightPalette {
  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color type;
  final Color function;
  final Color variable;
  final Color base;

  const HighlightPalette({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.type,
    required this.function,
    required this.variable,
    required this.base,
  });

  factory HighlightPalette.fromTheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    final semantic =
        theme.extension<SemanticColors>() ??
        SemanticColors.fallback(theme.brightness);
    return HighlightPalette(
      keyword: scheme.primary,
      string: semantic.success,
      comment: scheme.onSurfaceVariant.withAlpha(153),
      number: semantic.warning,
      type: semantic.info,
      function: scheme.secondary,
      variable: scheme.tertiary,
      base: scheme.onSurface,
    );
  }
}
