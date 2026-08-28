part of 'branch_toolbar.dart';

class _BranchItem extends StatelessWidget {
  final GitBranch? branch;
  final String? name;
  final bool isCurrent;
  final ThemeData theme;

  const _BranchItem({
    this.branch,
    this.name,
    required this.isCurrent,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final label = name ?? branch?.name ?? '';
    final ahead = branch?.ahead ?? 0;
    final behind = branch?.behind ?? 0;

    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isCurrent
                ? TextStyle(color: theme.colorScheme.primary)
                : null,
          ),
        ),
        if (behind > 0 || ahead > 0)
          Text(
            '↓$behind ↑$ahead',
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _WorktreeItem extends StatelessWidget {
  final String label;
  final String? sublabel;
  final bool isMain;
  final bool isCurrent;
  final ThemeData theme;

  const _WorktreeItem({
    required this.label,
    this.sublabel,
    this.isMain = false,
    this.isCurrent = false,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isCurrent
                    ? TextStyle(color: theme.colorScheme.primary)
                    : null,
              ),
              if (sublabel != null && sublabel!.isNotEmpty)
                Text(
                  sublabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool loading;
  final VoidCallback? onPressed;

  const _HeaderAction({
    required this.label,
    required this.tooltip,
    required this.loading,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(28, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}
