import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/material.dart';

/// Renders an `execute` tool call as a terminal-style block (like t3code).
/// The command is shown in a header bar with a status icon, and the output
/// is shown below in a monospace scroll area. No collapsible wrapper.
class RunCommandTool extends StatefulWidget {
  final ToolCallData tool;

  const RunCommandTool({super.key, required this.tool});

  @override
  State<RunCommandTool> createState() => _RunCommandToolState();
}

class _RunCommandToolState extends State<RunCommandTool> {
  bool _outputCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tool = widget.tool;
    final command = tool.command ?? '';
    final output = tool.output ?? '';

    final (statusIcon, statusColor) = switch (tool.status) {
      'completed' => (Icons.check_circle, theme.colorScheme.primary),
      'failed' => (Icons.cancel, theme.colorScheme.error),
      'pending' => (
          Icons.hourglass_empty,
          theme.colorScheme.onSurfaceVariant,
        ),
      _ => (
          Icons.play_circle_outline,
          theme.colorScheme.onSurfaceVariant,
        ),
    };

    final hasOutput = output.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, command, statusIcon, statusColor, hasOutput),
          if (hasOutput && !_outputCollapsed) _buildOutput(context, output),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    String command,
    IconData statusIcon,
    Color statusColor,
    bool hasOutput,
  ) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(5),
          topRight: Radius.circular(5),
        ),
      ),
      child: Row(
        children: [
          Icon(statusIcon, size: 14, color: statusColor),
          const SizedBox(width: 6),
          Icon(Icons.terminal, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              command,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasOutput) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: () => setState(() => _outputCollapsed = !_outputCollapsed),
              borderRadius: BorderRadius.circular(3),
              child: Icon(
                _outputCollapsed ? Icons.expand_more : Icons.expand_less,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutput(BuildContext context, String output) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(5),
              bottomRight: Radius.circular(5),
            ),
          ),
          child: SelectableText(
            output,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.4,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
