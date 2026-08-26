import 'package:flutter/material.dart';

import '../models/models.dart';

/// Right-side plan / task sidebar for a thread.
///
/// Shows the active plan explanation, a progress bar, and the ordered step
/// list. Steps are color-coded by status: pending, in-progress, completed.
class PlanSidebar extends StatelessWidget {
  final Plan? plan;
  final VoidCallback? onClose;
  final double width;

  const PlanSidebar({super.key, this.plan, this.onClose, this.width = 280});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectivePlan = plan;

    return SizedBox(
      width: width,
      child: Material(
        elevation: 1,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Plan',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onClose != null)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onClose,
                      tooltip: 'Close plan',
                    ),
                ],
              ),
            ),
            if (effectivePlan == null || effectivePlan.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'No plan yet',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              Expanded(child: _PlanContent(plan: effectivePlan)),
          ],
        ),
      ),
    );
  }
}

class _PlanContent extends StatelessWidget {
  final Plan plan;

  const _PlanContent({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (plan.explanation != null && plan.explanation!.isNotEmpty) ...[
          Text(
            plan.explanation!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
        ],
        _ProgressBar(percent: plan.progressPercent),
        const SizedBox(height: 16),
        ...plan.steps.map((s) => _StepRow(step: s)),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final int percent;

  const _ProgressBar({required this.percent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent / 100.0,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceDim,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$percent%',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(vertical: 6),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
