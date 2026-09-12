part of '../thread_page.dart';

class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool working;
  final bool hasText;
  const _ThinkingBlock({
    super.key,
    required this.text,
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
    // Auto-expand only when working flips on without reply text, matching
    // initState; a later chunk must not re-open a block the user collapsed.
    if (!old.working && widget.working && !widget.hasText && !_expanded) {
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

    final text = stripPlanMarkup(widget.text);

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
          secondChild: text.isEmpty
              ? const SizedBox.shrink(key: ValueKey('empty'))
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: theme.colorScheme.outline,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Row(
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
                          text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
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
