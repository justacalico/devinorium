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
                  status: status,
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
    final children = <Widget>[
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
        const SizedBox(width: 6),
        _ThreadMrChip(ref: thread.linkedMr!),
        const SizedBox(width: 4),
      ] else
        const SizedBox(width: 6),
      ProviderIcon(
        providerId: thread.providerId,
        size: 16,
        semanticLabel: providerName(thread.providerId),
      ),
    ];

    if (status != null) {
      children.insert(
        0,
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(
            status!.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: status!.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: children,
    );
  }
}

class _ThreadActions extends StatelessWidget {
  final ({Color color, String label})? status;
  final String time;
  final bool isDeleting;
  final Thread thread;
  final bool isRunning;
  final VoidCallback onDelete;

  const _ThreadActions({
    this.status,
    required this.time,
    required this.isDeleting,
    required this.thread,
    required this.isRunning,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

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
