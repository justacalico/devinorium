import 'package:flutter/material.dart';

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

  factory HighlightPalette.fromTheme(ThemeData theme) => HighlightPalette(
        keyword: theme.colorScheme.primary,
        string: const Color(0xFF4CAF50),
        comment: theme.colorScheme.onSurfaceVariant.withAlpha(153),
        number: const Color(0xFFFF9800),
        type: const Color(0xFFE91E63),
        function: const Color(0xFF2196F3),
        variable: const Color(0xFF9C27B0),
        base: theme.colorScheme.onSurface,
      );
}
