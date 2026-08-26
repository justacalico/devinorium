import 'package:flutter/material.dart';

import '../models/models.dart';

/// Floating plan overlay shown at the top of the chat.
///
/// Displays a compact summary when collapsed and expands to show the full step
/// list. The user can dismiss it with the close button.
class PlanOverlay extends StatelessWidget {
  final Plan? plan;
  final bool expanded;
  final bool dismissed;
  final VoidCallback onToggleExpand;
  final VoidCallback onDismiss;

  const PlanOverlay({
    super.key,
    this.plan,
    this.expanded = false,
    this.dismissed = false,
    required this.onToggleExpand,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final effectivePlan = plan;
    if (dismissed || effectivePlan == null || effectivePlan.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final percent = effectivePlan.progressPercent;
    final completed = effectivePlan.steps.where((s) => s.isCompleted).length;
    final total = effectivePlan.steps.length;
    final explanation = effectivePlan.explanation ?? 'Plan';

    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      shadowColor: theme.colorScheme.shadow.withAlpha(40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.checklist, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            explanation,
                            style: _emphasisStyle(theme),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$completed / $total steps · $percent%',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontFamilyFallback: _cjkFallback,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      onPressed: onToggleExpand,
                      tooltip: expanded ? 'Collapse plan' : 'Expand plan',
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: onDismiss,
                      tooltip: 'Hide plan',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: percent / 100.0,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  ),
                ),
                if (expanded) ...[
                  const SizedBox(height: 12),
                  _PlanSteps(plan: effectivePlan),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanSteps extends StatelessWidget {
  final Plan plan;

  const _PlanSteps({required this.plan});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: plan.steps.map((s) => _StepRow(step: s)).toList(),
    );
  }
}

class _StepRow extends StatelessWidget {
  final PlanStep step;

  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (icon, color) = switch (step.status) {
      'completed' => (Icons.check_circle, theme.colorScheme.primary),
      'in_progress' => (Icons.play_circle, theme.colorScheme.tertiary),
      _ => (Icons.radio_button_unchecked, theme.colorScheme.outline),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              step.step,
              style: theme.textTheme.bodyMedium?.copyWith(
                decoration: step.isCompleted
                    ? TextDecoration.lineThrough
                    : null,
                color: step.isCompleted
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                fontFamilyFallback: _cjkFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _cjkFallback = [
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Noto Sans CJK TC',
  'Noto Sans TC',
  'WenQuanYi Micro Hei',
  'Microsoft YaHei',
  'PingFang SC',
  'Hiragino Sans GB',
  'sans-serif',
];

TextStyle? _emphasisStyle(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      fontFamilyFallback: _cjkFallback,
    );
