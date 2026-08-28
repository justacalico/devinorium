part of '../sidebar.dart';

class _ProjectExpandableTile extends StatelessWidget {
  final int index;
  final Project project;
  final List<Thread> threads;
  final bool isExpanded;
  final String? activeThreadId;
  final VoidCallback onToggle;
  final VoidCallback? onNewThread;
  final ValueChanged<String> onThreadTap;

  const _ProjectExpandableTile({
    super.key,
    required this.index,
    required this.project,
    required this.threads,
    required this.isExpanded,
    this.activeThreadId,
    required this.onToggle,
    this.onNewThread,
    required this.onThreadTap,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final color = _projectColor(project.name);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: project.pinned
            ? Border(
                left: BorderSide(
                    color: theme.colorScheme.primary, width: 3))
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: _ProjectIcon(project: project, color: color),
                ),
                title: Tooltip(
                  message: project.path,
                  child: Text(
                    project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                subtitle: project.isRepo && project.gitBranch.isNotEmpty
                    ? Text(
                        project.gitBranch,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      )
                    : Text(
                        project.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onNewThread != null)
                      IconButton(
                        tooltip: l10n(context).newThreadIn(project.name),
                        icon: Icon(Icons.add,
                            size: 18, color: theme.colorScheme.onSurfaceVariant),
                        onPressed: onNewThread,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                      ),
                    Icon(
                      isExpanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    _ProjectOptionsMenu(project: project),
                  ],
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
                onTap: onToggle,
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: isExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: threads.isEmpty &&
                            !state.hasMoreProjectThreads(project.id)
                        ? const _NoThreads()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ...threads.map(
                                (t) => _ThreadTile(
                                  key: ValueKey(t.id),
                                  thread: t,
                                  isActive: activeThreadId == t.id,
                                  onTap: () => onThreadTap(t.id),
                                  onDelete: () => state.deleteThread(t.id),
                                ),
                              ),
                              if (state.hasMoreProjectThreads(project.id))
                                TextButton(
                                  onPressed: state
                                          .isLoadingMoreProjectThreads(project.id)
                                      ? null
                                      : () => state
                                          .loadMoreProjectThreads(project.id),
                                  child: state.isLoadingMoreProjectThreads(
                                          project.id)
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Text('Load more'),
                                ),
                            ],
                          ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ProjectOptionsMenu extends StatelessWidget {
  final Project project;

  const _ProjectOptionsMenu({required this.project});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            project.pinned
                ? Icons.push_pin_outlined
                : Icons.push_pin,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          child: Text(
              project.pinned ? l.unpin : l.pin),
          onPressed: () =>
              state.pinProject(project.id, !project.pinned),
        ),
        MenuItemButton(
          leadingIcon: Icon(Icons.edit_outlined,
              size: 18, color: theme.colorScheme.onSurface),
          child: Text(l.rename),
          onPressed: () =>
              state.openRenameProjectDialog(project.id, project.name),
        ),
        MenuItemButton(
          leadingIcon: Icon(Icons.delete_outline,
              size: 18, color: theme.colorScheme.error),
          child: Text(l.deleteProject),
          onPressed: () async {
            if (HardwareKeyboard.instance.isShiftPressed ||
                await _confirm(
                    context,
                    l10n(context)
                        .deleteProjectConfirm(project.name))) {
              state.deleteProject(project.id);
            }
          },
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          tooltip: l.options,
          icon: Icon(Icons.more_vert,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          onPressed: () {
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
