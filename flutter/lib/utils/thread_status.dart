import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/semantic_colors.dart';

/// The foreground and background colors used for a thread status tag.
///
/// The mapping lives here so the sidebar tile and the app bar tag share the
/// same theme-aware colors.
({Color color, Color background}) threadStatusStyle(
  ThemeData theme,
  String tag,
) {
  final semantic =
      theme.extension<SemanticColors>() ??
      SemanticColors.fallback(theme.brightness);
  final scheme = theme.colorScheme;
  return switch (tag.toLowerCase()) {
    'needs approval' => (
      color: semantic.warning,
      background: semantic.warningContainer,
    ),
    'running' || 'working' || 'needs answer' => (
      color: semantic.info,
      background: semantic.infoContainer,
    ),
    'failed' => (color: scheme.error, background: scheme.errorContainer),
    'done' || 'completed' => (
      color: semantic.success,
      background: semantic.successContainer,
    ),
    'stopped' => (
      color: scheme.onSurfaceVariant,
      background: scheme.surfaceContainerHighest,
    ),
    _ => (
      color: scheme.onSurfaceVariant,
      background: scheme.surfaceContainerHighest,
    ),
  };
}

String? activeThreadTag({
  required bool sending,
  required List<Message> messages,
  required PermissionRequest? pendingPermissionRequest,
  AskRequest? pendingAskRequest,
  String? runStatus,
}) {
  if (pendingPermissionRequest != null) return 'needs approval';
  if (pendingAskRequest != null) return 'needs answer';
  if (sending) return 'running';
  if (runStatus == 'stopped') return 'stopped';
  if (runStatus == 'failed') return 'failed';
  if (runStatus == 'completed') return 'done';

  if (messages.isEmpty) return null;
  final last = messages.last;
  return switch (last.role) {
    'error' => 'failed',
    'user' => 'working',
    'assistant' => 'done',
    _ => null,
  };
}
