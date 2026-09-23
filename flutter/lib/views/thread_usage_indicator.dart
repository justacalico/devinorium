import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

/// Recorded token usage for the active thread, shown at the right end of
/// the toolbar strip under the composer. Tapping it opens a details dialog
/// with the per-kind breakdown and the context reset action.
class ThreadUsageIndicator extends StatelessWidget {
  const ThreadUsageIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return Selector<AppState, ThreadContextUsage?>(
      selector: (_, s) => s.threadContextUsage,
      builder: (context, usage, _) {
        if (usage == null) return const SizedBox.shrink();
        final totals = usage.usage;
        return InkWell(
          key: const Key('thread_usage_indicator'),
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            final state = context.read<AppState>();
            showDialog(
              context: context,
              builder: (_) => ChangeNotifierProvider<AppState>.value(
                value: state,
                child: const _ThreadUsageDialog(),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.data_usage,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  l.threadUsage(
                    formatTokens(totals.inputTokens),
                    formatTokens(totals.outputTokens),
                  ),
                  key: const Key('thread_usage_text'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ThreadUsageDialog extends StatelessWidget {
  const _ThreadUsageDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final usage = context.select<AppState, ThreadContextUsage?>(
      (s) => s.threadContextUsage,
    );
    // The reset endpoint 409s while a run is active, so the button hides
    // until the thread is idle again.
    final sending = context.select<AppState, bool>((s) => s.sending);
    final totals = usage?.usage ?? emptyUsageTotals;
    final cached = totals.cachedReadTokens + totals.cachedWriteTokens;

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );

    return AlertDialog(
      title: Text(l.usage),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(l.usageInput, formatTokens(totals.inputTokens)),
          row(l.usageOutput, formatTokens(totals.outputTokens)),
          if (totals.thoughtTokens > 0)
            row(l.usageReasoning, formatTokens(totals.thoughtTokens)),
          if (cached > 0) row(l.usageCached, formatTokens(cached)),
          const Divider(height: 16),
          row(l.usageTotalTokens, formatTokens(totals.totalTokens)),
          row(l.usageTurns, '${totals.records}'),
          for (final c in totals.costs)
            row(l.usageCost, '${c.amount.toStringAsFixed(2)} ${c.currency}'),
        ],
      ),
      actions: [
        if (usage?.hasSession == true && !sending)
          TextButton.icon(
            key: const Key('thread_usage_reset'),
            onPressed: () => context.read<AppState>().resetThreadContext(),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: Text(l.resetContext),
          ),
        TextButton(
          key: const Key('thread_usage_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.close),
        ),
      ],
    );
  }
}
