part of '../thread_page.dart';

class _ThinkingBlock extends StatefulWidget {
  final List<_ThinkingItem> items;
  final bool working;
  final bool hasText;
  const _ThinkingBlock({
    super.key,
    required this.items,
    required this.working,
    required this.hasText,
  });

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.working && !widget.hasText;
  }

  @override
  void didUpdateWidget(covariant _ThinkingBlock old) {
    super.didUpdateWidget(old);
    if ((!old.hasText && widget.hasText) ||
        (old.working && !widget.working && widget.hasText)) {
      if (_expanded) setState(() => _expanded = false);
      return;
    }
    if (widget.working && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final label = widget.working
        ? l.thinking
        : (_expanded ? l.hideThinking : l.showThinking);

    Widget expandedContent() {
      final children = <Widget>[];
      for (final item in widget.items) {
        if (item.type == 'thinking' && (item.content?.isNotEmpty ?? false)) {
          children.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stripPlanMarkup(item.content!),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          );
        } else if (item.type == 'tool_call') {
          final tool = item.tool;
          if (tool != null) {
            children.add(_ToolCallItem(tool: tool));
          }
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (widget.working) _ThinkingDots(active: widget.working),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.outline, width: 2),
              ),
            ),
            child: expandedContent(),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeInOut,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
