import 'package:flutter/material.dart';

import '../theme/semantic_colors.dart';

/// Color for a git file status label, shared by the file tree's status
/// coloring and the Git panel's status badges.
Color gitStatusColor(String status, ThemeData theme) {
  final semantic =
      theme.extension<SemanticColors>() ??
      SemanticColors.fallback(theme.brightness);
  final scheme = theme.colorScheme;
  return switch (status) {
    'modified' || 'descendant' => semantic.warning,
    'added' || 'copied' => semantic.success,
    'deleted' || 'conflict' => scheme.error,
    'renamed' || 'untracked' => semantic.info,
    'ignored' => scheme.onSurfaceVariant,
    _ => scheme.onSurfaceVariant,
  };
}

/// Short letter badge for a git file status, like `git status --short`.
String gitStatusLetter(String status) {
  return switch (status) {
    'modified' => 'M',
    'added' => 'A',
    'deleted' => 'D',
    'renamed' => 'R',
    'copied' => 'C',
    'untracked' => 'U',
    'conflict' => '!',
    _ => '?',
  };
}
