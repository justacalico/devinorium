part of '../thread_page.dart';

/// Collapsed summary for a streak of finished tool calls. Expands to show the
/// individual tool rows.
class _ToolGroupRow extends StatefulWidget {
  final List<ToolCallData> tools;
  const _ToolGroupRow({super.key, required this.tools});

  @override
  State<_ToolGroupRow> createState() => _ToolGroupRowState();
}

class _ToolGroupRowState extends State<_ToolGroupRow> {
  bool _expanded = false;

  String _summary(AppLocalizations l) {
    final c = toolGroupCounts(widget.tools);
    final parts = <String>[
      if (c.reads > 0) l.toolGroupReadFiles(c.reads),
      if (c.edits > 0) l.toolGroupChangedFiles(c.edits),
      if (c.commands > 0) l.toolGroupRanCommands(c.commands),
      if (c.searches > 0) l.toolGroupSearched(c.searches),
      if (c.others > 0) l.toolGroupUsedTools(c.others),
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final hasFailed = widget.tools.any((t) => t.status == 'failed');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: _expanded
                  ? theme.colorScheme.surfaceContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            margin: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Icon(
                  Icons.handyman_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _summary(l),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasFailed)
                  Icon(
                    Icons.error_outline,
                    size: 14,
                    color: theme.colorScheme.error,
                  )
                else
                  Icon(Icons.check, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.tools.length; i++)
                  _ToolCallItem(key: ValueKey(i), tool: widget.tools[i]),
              ],
            ),
          ),
      ],
    );
  }
}
