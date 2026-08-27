part of '../thread_page.dart';

class _ToolCallItem extends StatefulWidget {
  final ToolCallData tool;
  const _ToolCallItem({super.key, required this.tool});

  @override
  State<_ToolCallItem> createState() => _ToolCallItemState();
}

class _ToolCallItemState extends State<_ToolCallItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final tool = widget.tool;
    final preview = tool.outputPreview ?? tool.command ?? '';

    if (tool.kind == 'read') {
      return ReadFileTool(key: ValueKey(tool.id), tool: tool);
    }

    if (tool.kind == 'edit') {
      return EditFileTool(key: ValueKey(tool.id), tool: tool);
    }

    if (tool.kind == 'execute') {
      return RunCommandTool(key: ValueKey(tool.id), tool: tool);
    }

    final (icon, iconColor) = _toolIconAndColor(tool.kind, theme);

    final (statusIcon, statusColor) = switch (tool.status) {
      'completed' => (Icons.check, theme.colorScheme.primary),
      'failed' => (Icons.error_outline, theme.colorScheme.error),
      'pending' => (Icons.hourglass_empty, theme.colorScheme.onSurfaceVariant),
      _ => (Icons.play_circle_outline, theme.colorScheme.onSurfaceVariant),
    };

    return InkWell(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tool.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(statusIcon, size: 14, color: statusColor),
                const SizedBox(width: 4),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.isNotEmpty)
                      _ToolDetailRow(label: l.preview, value: preview),
                    if (tool.command != null && tool.command!.isNotEmpty)
                      _ToolDetailRow(label: l.command, value: tool.command!),
                    if (tool.output != null && tool.output!.isNotEmpty)
                      _ToolDetailRow(label: l.output, value: tool.output!),
                    if (tool.changedFiles.isNotEmpty)
                      _ToolDetailRow(
                        label: l.changed,
                        value: tool.changedFiles.join('\n'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
