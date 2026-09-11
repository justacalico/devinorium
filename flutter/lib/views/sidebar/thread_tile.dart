part of '../sidebar.dart';

class _ThreadTile extends StatefulWidget {
  final Thread thread;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ThreadTile({
    super.key,
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
    if (_deleting || !mounted) return;
    setState(() => _deleting = true);
    _pendingDelete = true;
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final time = _timeAgo(widget.thread.updatedAt, l);

    return Selector<AppState, ({Color? dotColor, String? dotLabel, bool isRunning})>(
      selector: (_, state) {
        final s = _threadStatus(context, state, widget.thread);
        return (
          dotColor: s?.color,
          dotLabel: s?.label,
          isRunning: state.runningThreadIds.contains(widget.thread.id),
        );
      },
      builder: (context, model, _) {
        final status = model.dotColor != null && model.dotLabel != null
            ? (color: model.dotColor!, label: model.dotLabel!)
            : null;

        return SlideTransition(
          position: _slide,
          transformHitTests: false,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: widget.isActive
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
                  : theme.colorScheme.surfaceContainer.withValues(alpha: 0.5),
              border: widget.isActive
                  ? Border.all(color: theme.colorScheme.primary, width: 1.5)
                  : (widget.thread.pinned
                      ? Border(
                          left: BorderSide(
                              color: theme.colorScheme.primary, width: 3))
                      : null),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: _StatusDot(status: status),
                title: _ThreadTitle(
                  thread: widget.thread,
                  status: status,
                  isActive: widget.isActive,
                ),
                trailing: _ThreadActions(
                  time: time,
                  isDeleting: _deleting,
                  thread: widget.thread,
                  isRunning: model.isRunning,
                  onDelete: _delete,
                ),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                horizontalTitleGap: 8,
                minLeadingWidth: 0,
                minVerticalPadding: 0,
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

class _StatusDot extends StatelessWidget {
  final ({Color color, String label})? status;

  const _StatusDot({this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) {
      return const SizedBox(width: 8, height: 8);
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: status!.color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ThreadMrBadge extends StatelessWidget {
  final Thread thread;
  final bool isActive;

  const _ThreadMrBadge({required this.thread, required this.isActive});

  @override
  Widget build(BuildContext context) {
    if (thread.linkedMr == null && !isActive) {
      return const SizedBox.shrink();
    }

    return Selector<AppState, MergeRequestLink?>(
      selector: (_, state) =>
          isActive && state.activeThreadId == thread.id
              ? state.linkedMergeRequest
              : null,
      builder: (context, live, _) {
        final ref = thread.linkedMr;
        if (ref == null && live == null) {
          return const SizedBox.shrink();
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MrChipBody(ref: ref, live: live),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }
}

class _MrChipBody extends StatelessWidget {
  final LinkedMergeRequestRef? ref;
  final MergeRequestLink? live;

  const _MrChipBody({this.ref, this.live});

  @override
  Widget build(BuildContext context) {
    final iid = live?.iid ?? ref?.iid ?? 0;
    final url = live?.webUrl ?? ref?.webUrl ?? '';
    if (iid == 0 || url.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = '!$iid';
    final isDraft = live?.draft ?? false;
    final state = live?.state ?? '';

    final ({Color fg, Color bg}) style = switch (state) {
      _ when isDraft => (
          fg: colorScheme.error,
          bg: colorScheme.errorContainer.withValues(alpha: 0.3)
        ),
      'merged' => (
          fg: colorScheme.tertiary,
          bg: colorScheme.tertiaryContainer.withValues(alpha: 0.3)
        ),
      'closed' => (
          fg: colorScheme.error,
          bg: colorScheme.errorContainer.withValues(alpha: 0.3)
        ),
      'opened' || 'open' => (
          fg: colorScheme.primary,
          bg: colorScheme.primaryContainer.withValues(alpha: 0.3)
        ),
      _ => (
          fg: colorScheme.secondary,
          bg: colorScheme.secondaryContainer.withValues(alpha: 0.5)
        )
    };

    final title = live?.title;
    final source = live?.sourceBranch;
    final target = live?.targetBranch;
    final parts = [label];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (source != null && source.isNotEmpty && target != null && target.isNotEmpty) {
      parts.add('$source → $target');
    }
    parts.add(url);
    final tooltip = parts.join(' · ');

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.read<AppState>().openLink(url),
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: url));
          if (context.mounted) {
            showAppMessage(
              context,
              l10n(context).copiedToClipboard,
              kind: MessageKind.success,
              duration: const Duration(seconds: 1),
            );
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: style.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: style.fg.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.merge,
                size: 11,
                color: style.fg,
                semanticLabel: 'Merge request $iid',
              ),
              const SizedBox(width: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: style.fg,
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
  final ({Color color, String label})? status;
  final bool isActive;

  const _ThreadTitle({
    required this.thread,
    this.status,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final worktreeName = thread.worktreeName;
    final children = <Widget>[
      ProviderIcon(
        providerId: thread.providerId,
        size: 16,
        semanticLabel: providerName(thread.providerId),
      ),
      const SizedBox(width: 6),
      if (status != null) ...[
        Text(
          status!.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: status!.color,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
      ],
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
      _ThreadMrBadge(thread: thread, isActive: isActive),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.max,
          children: children,
        ),
        if (worktreeName != null) ...[
          const SizedBox(height: 2),
          _ThreadWorktreeLabel(
            name: worktreeName,
            tooltip: _worktreeTooltip(thread, worktreeName),
          ),
        ],
      ],
    );
  }
}

class _ThreadWorktreeLabel extends StatelessWidget {
  final String name;
  final String tooltip;

  const _ThreadWorktreeLabel({
    required this.name,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Icon(Icons.fork_right, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _worktreeTooltip(Thread thread, String worktreeName) {
  if (thread.worktreePath?.isNotEmpty == true) return thread.worktreePath!;
  if (thread.branch?.isNotEmpty == true) return thread.branch!;
  return worktreeName;
}

class _ThreadActions extends StatelessWidget {
  final String time;
  final bool isDeleting;
  final Thread thread;
  final bool isRunning;
  final VoidCallback onDelete;

  const _ThreadActions({
    required this.time,
    required this.isDeleting,
    required this.thread,
    required this.isRunning,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isRunning)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        if (time.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              time,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        _ThreadOptionsMenu(
          thread: thread,
          isDeleting: isDeleting,
          onDelete: onDelete,
        ),
      ],
    );
  }
}

class _ThreadOptionsMenu extends StatelessWidget {
  final Thread thread;
  final bool isDeleting;
  final VoidCallback onDelete;

  const _ThreadOptionsMenu({
    required this.thread,
    required this.isDeleting,
    required this.onDelete,
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
          onPressed: isDeleting
              ? null
              : () => state.pinThread(thread.id, !thread.pinned),
          child: Text(thread.pinned ? l.unpin : l.pin),
        ),
        MenuItemButton(
          leadingIcon: Icon(Icons.edit_outlined,
              size: 18, color: theme.colorScheme.onSurface),
          onPressed: isDeleting
              ? null
              : () => state.openRenameThreadDialog(thread.id, thread.title),
          child: Text(l.rename),
        ),
        if (thread.linkedMr != null)
          MenuItemButton(
            leadingIcon: Icon(Icons.link_off,
                size: 18, color: theme.colorScheme.onSurface),
            onPressed: isDeleting
                ? null
                : () => state.unlinkThreadLinkedMr(thread.id),
            child: Text(l.unlinkMergeRequest),
          )
        else
          MenuItemButton(
            leadingIcon: Icon(Icons.merge,
                size: 18, color: theme.colorScheme.primary),
            onPressed: isDeleting
                ? null
                : () async {
                    final url = await showDialog<String?>(
                      context: context,
                      builder: (_) => const LinkMergeRequestDialog(),
                    );
                    if (url != null && url.isNotEmpty) {
                      await state.setThreadLinkedMr(thread.id, url);
                      if (!context.mounted) return;
                      if (state.globalError.isNotEmpty) {
                        showAppMessage(
                          context,
                          state.globalError,
                          kind: MessageKind.error,
                        );
                      }
                    }
                  },
            child: Text(l.linkMergeRequest),
          ),
        MenuItemButton(
          leadingIcon: Icon(Icons.delete_outline,
              size: 18, color: theme.colorScheme.error),
          onPressed: isDeleting
              ? null
              : () async {
                  if (HardwareKeyboard.instance.isShiftPressed ||
                      await _confirm(context, l.deleteThreadConfirm)) {
                    if (!context.mounted) return;
                    onDelete();
                  }
                },
          child: Text(l.deleteThread),
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
