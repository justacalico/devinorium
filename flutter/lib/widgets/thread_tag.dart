import 'package:flutter/material.dart';

class ThreadTag extends StatelessWidget {
  final String tag;

  const ThreadTag(this.tag, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, backgroundColor) = _colors(theme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _label(tag),
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  (Color, Color) _colors(ThemeData theme) {
    final cs = theme.colorScheme;
    return switch (tag.toLowerCase()) {
      'needs approval' => (cs.primary, cs.primaryContainer),
      'working' => (cs.tertiary, cs.tertiaryContainer),
      'failed' => (Color(0xFFB3261E), cs.errorContainer),
      'completed' => (cs.secondary, cs.secondaryContainer),
      _ => (cs.onSurfaceVariant, cs.surfaceContainerHighest),
    };
  }

  String _label(String tag) {
    if (tag.isEmpty) return tag;
    return tag.substring(0, 1).toUpperCase() + tag.substring(1);
  }
}
