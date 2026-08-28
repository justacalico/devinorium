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
      widget.onDelete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _delete() {
    if (_deleting) return;
    setState(() => _deleting = true);
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);
    final time = _timeAgo(widget.thread.updatedAt, l);
    return SlideTransition(
      position: _slide,
      transformHitTests: false,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
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
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            title: Text(
              widget.thread.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: (widget.isActive || widget.thread.pinned)
                    ? FontWeight.w600
                    : null,
              ),
            ),
            subtitle: _threadSubtitle(widget.thread, theme),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.runningThreadIds.contains(widget.thread.id))
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
                  Text(
                    time,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                const SizedBox(width: 4),
                MenuAnchor(
                  menuChildren: [
                    MenuItemButton(
                      leadingIcon: Icon(
                        widget.thread.pinned
                            ? Icons.push_pin_outlined
                            : Icons.push_pin,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      child: Text(widget.thread.pinned ? l.unpin : l.pin),
                      onPressed: () =>
                          state.pinThread(widget.thread.id, !widget.thread.pinned),
                    ),
                    MenuItemButton(
                      leadingIcon: Icon(Icons.edit_outlined,
                          size: 18, color: theme.colorScheme.onSurface),
                      child: Text(l.rename),
                      onPressed: () =>
                          state.openRenameThreadDialog(widget.thread.id, widget.thread.title),
                    ),
                  ],
                  builder: (context, controller, child) {
                    return IconButton(
                      tooltip: l.options,
                      icon: Icon(Icons.more_vert,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: _deleting
                          ? null
                          : () {
                              if (controller.isOpen) {
                                controller.close();
                              } else {
                                controller.open();
                              }
                            },
                    );
                  },
                ),
                IconButton(
                  tooltip: l.deleteThreadTooltip,
                  icon: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error, size: 18),
                  onPressed: _deleting
                      ? null
                      : () async {
                          if (HardwareKeyboard.instance.isShiftPressed ||
                              await _confirm(context, l.deleteThreadConfirm)) {
                            _delete();
                          }
                        },
                ),
              ],
            ),
            dense: true,
            onTap: _deleting
                ? null
                : () {
                    // Close the drawer if open (mobile layout).
                    Scaffold.of(context).closeDrawer();
                    widget.onTap();
                  },
          ),
        ),
      ),
    );
  }
}
