import 'package:flutter/material.dart';

/// The icon shown for a provider (CLI) in the model selector. Unknown
/// providers fall back to a generic terminal icon so new providers render
/// without a code change.
class ProviderIcon extends StatelessWidget {
  final String providerId;
  final double size;
  final Color? color;

  const ProviderIcon({
    super.key,
    required this.providerId,
    this.size = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;
    return Icon(
      providerIconData(providerId),
      size: size,
      color: effectiveColor,
    );
  }
}

IconData providerIconData(String providerId) => switch (providerId) {
  'devin-cli' => Icons.auto_awesome,
  'opencode' => Icons.code,
  'codex' => Icons.terminal,
  _ => Icons.smart_toy_outlined,
};
