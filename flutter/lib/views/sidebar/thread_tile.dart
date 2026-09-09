part of '../sidebar.dart';

class _ThreadTile extends StatefulWidget {
  final Project project;
  final Thread thread;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ThreadTile({
    super.key,
    required this.project,
    required this.thread,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_ThreadTile> createState() => _ThreadTileState();
}

class _ThreadTileState extends State<_ThreadTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  bool _deleting = false;
  bool _pendingDelete = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _slide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-1.0, 0.0),
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
    _controller.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      _pendingDelete = false;
      widget.onDelete();
    }
  }

  @override
  void dispose() {
    if (_pendingDelete) widget.onDelete();
    _controller.dispose();
    super.dispose();
  }

  void _delete() {
    if (_deleting) return;
    setState(() => _deleting = true);
    _pendingDelete = true;
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final time = _timeAgo(widget.thread.updatedAt, l);

    return Selector<AppState, ({Color? dotColor, String? dotLabel})>(
      selector: (_, state) {
        final s = _threadStatus(context, state, widget.thread);
        return (
          dotColor: s?.color,
          dotLabel: s?.label,
        );
      },
      builder: (context, model, _) {
        final status = model.dotColor != null && model.dotLabel != null
            ? (color: model.dotColor!, label: model.dotLabel!)
            : null;

        final branch = widget.thread.branch?.trim() ?? '';
        final worktreePath = widget.thread.worktreePath?.trim() ?? '';
        final hasSubtitle = branch.isNotEmpty ||
            worktreePath.isNotEmpty ||
            status != null ||
            time.isNotEmpty;

        BoxDecoration? decoration;
        if (widget.isActive) {
          decoration = BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.20),
            borderRadius: BorderRadius.circular(8),
          );
        } else if (widget.thread.pinned) {
          decoration = BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.colorScheme.primary, width: 3),
            ),
            borderRadius: BorderRadius.circular(8),
          );
        }

        return SlideTransition(
          position: _slide,
          transformHitTests: false,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: decoration,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: _ThreadLeading(
                  project: widget.project,
                  status: status,
                ),
                title: _ThreadTitle(
                  thread: widget.thread,
                  isActive: widget.isActive,
                ),
                subtitle: hasSubtitle
                    ? _ThreadSubtitle(
                        thread: widget.thread,
                        status: status,
                        time: time,
                      )
                    : null,
                trailing: _ThreadActions(
                  thread: widget.thread,
                  isDeleting: _deleting,
                  onDelete: _delete,
                ),
                dense: true,
                visualDensity: VisualDensity.compact,
                tileColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                horizontalTitleGap: 8,
                minLeadingWidth: 0,
                minVerticalPadding: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                onTap: _deleting
                    ? null
                    : () {
                        Scaffold.of(context).closeDrawer();
                        widget.onTap();
                      },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ThreadLeading extends StatelessWidget {
  final Project project;
  final ({Color color, String label})? status;

  const _ThreadLeading({
    required this.project,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _projectColor(project.name);

    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: _ProjectIcon(project: project, color: color),
          ),
          if (status != null)
            Align(
              alignment: Alignment.bottomRight,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: status!.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThreadMrChip extends StatelessWidget {
  final LinkedMergeRequestRef ref;

  const _ThreadMrChip({required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = '!${ref.iid}';
    final url = ref.webUrl;
    final tooltip = url.isEmpty ? label : '$label · $url';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: url.isEmpty
            ? null
            : () => context.read<AppState>().openLink(url),
        onLongPress: url.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n(context).copiedToClipboard),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colorScheme.secondary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.merge,
                size: 11,
                color: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreadTitle extends StatelessWidget {
  final Thread thread;
  final bool isActive;

  const _ThreadTitle({
    required this.thread,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Text(
            thread.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: (isActive || thread.pinned)
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(width: 6),
        if (thread.linkedMr != null) ...[
          _ThreadMrChip(ref: thread.linkedMr!),
          const SizedBox(width: 4),
        ],
        ProviderIcon(
          providerId: thread.providerId,
          size: 16,
          semanticLabel: providerName(thread.providerId),
        ),
      ],
    );
  }
}

class _ThreadSubtitle extends StatelessWidget {
  final Thread thread;
  final ({Color color, String label})? status;
  final String time;

  const _ThreadSubtitle({
    required this.thread,
    this.status,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final branch = thread.branch?.trim() ?? '';
    final worktreePath = thread.worktreePath?.trim() ?? '';
    final hasBranch = branch.isNotEmpty;
    final hasWorktree = worktreePath.isNotEmpty;

    if (!hasBranch && !hasWorktree && status == null && time.isEmpty) {
      return const SizedBox.shrink();
    }

    final metadata = _buildMetadata(context, l, hasBranch, hasWorktree, branch, worktreePath);

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        metadata ?? const Spacer(),
        if (status != null) ...[
          const SizedBox(width: 8),
          Text(
            status!.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: status!.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (time.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            time,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget? _buildMetadata(
    BuildContext context,
    AppLocalizations l,
    bool hasBranch,
    bool hasWorktree,
    String branch,
    String worktreePath,
  ) {
    final theme = Theme.of(context);
    final iconColor = theme.colorScheme.onSurfaceVariant;

    if (hasWorktree) {
      final label = hasBranch ? branch : _formatWorktreePathForDisplay(worktreePath);
      final tooltip = hasBranch
          ? l.threadWorktreeBranchTooltip(worktreePath, branch)
          : l.threadWorktreeTooltip(worktreePath);

      return Expanded(
        child: Tooltip(
          message: tooltip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_copy,
                size: 12,
                semanticLabel: l.worktreeMode,
                color: iconColor,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (hasBranch) {
      return Expanded(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.call_split,
              size: 12,
              semanticLabel: l.gitBranches,
              color: iconColor,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                branch,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return null;
  }
}

String _formatWorktreePathForDisplay(String worktreePath) {
  final trimmed = worktreePath.trim();
  if (trimmed.isEmpty) return worktreePath;

  final normalized =
      trimmed.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
  final last = parts.isNotEmpty ? parts.last.trim() : '';
  if (last.isNotEmpty) return last;
  return normalized.isEmpty ? '/' : normalized;
}

class _ThreadActions extends StatelessWidget {
  final Thread thread;
  final bool isDeleting;
  final VoidCallback onDelete;

  const _ThreadActions({
    required this.thread,
    required this.isDeleting,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ThreadOptionsMenu(
          thread: thread,
          isDeleting: isDeleting,
        ),
        IconButton(
          tooltip: l.deleteThreadTooltip,
          icon: Icon(Icons.delete_outline,
              color: theme.colorScheme.error, size: 18),
          onPressed: isDeleting
              ? null
              : () async {
                  if (HardwareKeyboard.instance.isShiftPressed ||
                      await _confirm(context, l.deleteThreadConfirm)) {
                    onDelete();
                  }
                },
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
        ),
      ],
    );
  }
}

class _ThreadOptionsMenu extends StatelessWidget {
  final Thread thread;
  final bool isDeleting;

  const _ThreadOptionsMenu({
    required this.thread,
    required this.isDeleting,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            thread.pinned
                ? Icons.push_pin_outlined
                : Icons.push_pin,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          child: Text(thread.pinned ? l.unpin : l.pin),
          onPressed: () =>
              state.pinThread(thread.id, !thread.pinned),
        ),
        MenuItemButton(
          leadingIcon: Icon(Icons.edit_outlined,
              size: 18, color: theme.colorScheme.onSurface),
          child: Text(l.rename),
          onPressed: () =>
              state.openRenameThreadDialog(thread.id, thread.title),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          tooltip: l.options,
          icon: Icon(Icons.more_vert,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          onPressed: isDeleting
              ? null
              : () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
        );
      },
    );
  }
}
