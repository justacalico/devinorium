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
    final isRemote = branch?.isRemote ?? false;

    return Row(
      children: [
        Icon(
          isCurrent
              ? Icons.check_circle
              : (isRemote ? Icons.cloud : Icons.call_split),
          size: 16,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
    final display = sublabel != null && sublabel!.isNotEmpty
        ? '$label — $sublabel'
        : label;
    return Row(
      children: [
        Icon(
          isCurrent ? Icons.check_circle : (isMain ? Icons.folder : Icons.folder_copy),
          size: 16,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
        width: 40,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}
