import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/owner_badge.dart';
import 'project_icon.dart';

Color _projectColor(String name) {
  final colors = [
    Colors.pink,
    Colors.green,
    Colors.purple,
    Colors.orange,
    Colors.blue,
    Colors.teal,
    Colors.indigo,
    Colors.red,
  ];
  var hash = 0;
  for (var i = 0; i < name.length; i++) {
    hash = ((hash << 5) - hash) + name.codeUnitAt(i);
    hash &= 0x3fffffff;
  }
  return colors[hash % colors.length];
}

String _timeAgo(String iso, AppLocalizations l) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final now = DateTime.now().toUtc();
  final diff = now.difference(dt.toUtc());
  if (diff.inSeconds < 60) return l.timeAgoJustNow;
  if (diff.inMinutes < 60) return l.timeAgoMinutes(diff.inMinutes);
  if (diff.inHours < 24) return l.timeAgoHours(diff.inHours);
  if (diff.inDays < 30) return l.timeAgoDays(diff.inDays);
  if (diff.inDays < 365) return l.timeAgoMonths((diff.inDays / 30).floor());
  return l.timeAgoYears((diff.inDays / 365).floor());
}

/// The sidebar: projects, threads, and user menu.
/// When the user is on the Settings page, the sidebar shows settings topics
/// with a back button instead of the project/thread list.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final user = state.user;
    final username = user?.username ?? '';
    final avatar =
        username.isNotEmpty ? username[0].toUpperCase() : '?';
    final isSettings = state.page == MainPage.settings;

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                if (isSettings)
                  IconButton(
                    onPressed: () {
                      Scaffold.of(context).closeDrawer();
                      state.setPage(MainPage.threads);
                    },
                    icon: const Icon(Icons.arrow_back),
                    tooltip: l10n(context).back,
                  )
                else
                  Icon(Icons.folder_outlined,
                      color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isSettings ? l10n(context).settings : l10n(context).projects,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (!isSettings)
                  IconButton(
                    onPressed: () => state.openNewProjectDialog(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: l10n(context).newProject,
                  ),
              ],
            ),
          ),
          // Project/thread list or settings navigation
          Expanded(
            child: isSettings
                ? const _SettingsNav()
                : const _ProjectThreadList(),
          ),
          // User chip + menu
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      child: Text(avatar),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        username,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                    const _ConnectionStatusIcon(),
                    MenuAnchor(
                      menuChildren: [
                        MenuItemButton(
                          leadingIcon: const Icon(Icons.settings_outlined),
                          child: Text(l10n(context).settings),
                          onPressed: () {
                            state.setPage(MainPage.settings);
                            state.setUserMenuOpen(false);
                          },
                        ),
                        MenuItemButton(
                          leadingIcon: const Icon(Icons.logout),
                          child: Text(l10n(context).signOut),
                          onPressed: () => state.logout(),
                        ),
                      ],
                      builder: (context, controller, child) {
                        return IconButton(
                          tooltip: l10n(context).menu,
                          icon: const Icon(Icons.more_vert),
                          onPressed: () {
                            if (controller.isOpen) {
                              controller.close();
                            } else {
                              controller.open();
                            }
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A combined list of projects, each expandable to show its threads.
class _ProjectThreadList extends StatefulWidget {
  const _ProjectThreadList();

  @override
  State<_ProjectThreadList> createState() => _ProjectThreadListState();
}

class _ProjectThreadListState extends State<_ProjectThreadList> {
  final Set<int> _expandedIds = {};
  int? _lastActiveProjectId;
  String? _lastActiveThreadId;
  List<Thread> _lastThreads = [];
  Timer? _pollTimer;
  final ScrollController _scrollController = ScrollController();
  static const _loadMoreThreshold = 200.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (mounted) context.read<AppState>().refreshRunningThreads();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshRunningThreads();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final state = context.read<AppState>();
    final pos = _scrollController.position;
    if (state.hasMoreProjects &&
        !state.isLoadingMoreProjects &&
        pos.pixels >= pos.maxScrollExtent - _loadMoreThreshold) {
      state.loadMoreProjects();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    final activeProjectId = state.activeProjectId;
    final activeThreadId = state.activeThreadId;
    final threads = state.threads;
    final projects = state.projects;

    if (activeThreadId != _lastActiveThreadId ||
        activeProjectId != _lastActiveProjectId ||
        threads != _lastThreads) {
      _lastActiveThreadId = activeThreadId;
      _lastActiveProjectId = activeProjectId;
      _lastThreads = threads;

      // On initial load no thread is selected, so all projects start collapsed.
      // When a thread becomes active, expand the project that owns it.
      if (activeThreadId != null) {
        final projectId = _projectIdForThread(threads, activeThreadId) ??
            activeProjectId;
        if (projectId != null && !_expandedIds.contains(projectId)) {
          setState(() {
            _expandedIds.add(projectId);
          });
        }
      }
    }

    _expandedIds.removeWhere((id) => !projects.any((p) => p.id == id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects;
    final threads = state.threads;
    final activeThreadId = state.activeThreadId;

    if (projects.isEmpty) {
      return const _NoProjects();
    }

    final threadsByProject = <int, List<Thread>>{};
    for (final t in threads) {
      if (t.projectId != 0) {
        threadsByProject.putIfAbsent(t.projectId, () => []).add(t);
      }
    }
    for (final list in threadsByProject.values) {
      list.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    }

    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            scrollController: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            buildDefaultDragHandles: false,
            onReorderItem: _onReorder,
            itemCount: projects.length,
            itemBuilder: (context, index) {
              final p = projects[index];
              return _ProjectExpandableTile(
                key: ValueKey(p.id),
                index: index,
                project: p,
                threads: threadsByProject[p.id] ?? [],
                isExpanded: _expandedIds.contains(p.id),
                activeThreadId: activeThreadId,
                onToggle: () => _onToggle(p.id),
                onNewThread: () {
                  Scaffold.of(context).closeDrawer();
                  state.createNewThread(projectId: p.id);
                },
                onThreadTap: (id) => state.openThread(id),
              );
            },
          ),
        ),
        if (state.hasMoreProjects || state.isLoadingMoreProjects)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: state.isLoadingMoreProjects
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => state.loadMoreProjects(),
                    child: const Text('Load more'),
                  ),
          ),
      ],
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    final state = context.read<AppState>();
    final ids = state.projects.map((p) => p.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    state.reorderProjects(ids);
  }

  void _onToggle(int id) {
    final state = context.read<AppState>();
    if (_expandedIds.contains(id)) {
      setState(() {
        _expandedIds.remove(id);
      });
    } else {
      setState(() {
        _expandedIds.add(id);
      });
      state.selectProject(id);
    }
  }

  int? _projectIdForThread(List<Thread> threads, String threadId) {
    for (final t in threads) {
      if (t.id == threadId) return t.projectId;
    }
    return null;
  }
}

class _ProjectIcon extends StatelessWidget {
  final Project project;
  final Color color;

  const _ProjectIcon({required this.project, required this.color});

  @override
  Widget build(BuildContext context) {
    final icon = projectIconForType(project.projectType);
    // For generic projects, fall back to the first-letter avatar.
    if (project.projectType == 'generic') {
      return Text(
        project.name.isNotEmpty ? project.name[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 14,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Icon(icon.icon, size: 20, color: Colors.white);
  }
}

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
    final isRepo = project.isRepo;
    final theme = Theme.of(context);
    final color = _projectColor(project.name);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
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
                borderRadius: BorderRadius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
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
                  if (isRepo)
                    IconButton(
                      tooltip: project.gitBranch.isNotEmpty
                          ? project.gitBranch
                          : l10n(context).gitBranches,
                      icon: Icon(Icons.call_split,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: () => state.openGitBranchDialog(project.id),
                    ),
                  if (onNewThread != null)
                    IconButton(
                      tooltip: l10n(context).newThreadIn(project.name),
                      icon: Icon(Icons.add,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: onNewThread,
                    ),
                  MenuAnchor(
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
                            project.pinned ? l10n(context).unpin : l10n(context).pin),
                        onPressed: () =>
                            state.pinProject(project.id, !project.pinned),
                      ),
                      MenuItemButton(
                        leadingIcon: Icon(Icons.edit_outlined,
                            size: 18, color: theme.colorScheme.onSurface),
                        child: Text(l10n(context).rename),
                        onPressed: () =>
                            state.openRenameProjectDialog(project.id, project.name),
                      ),
                      MenuItemButton(
                        leadingIcon: Icon(Icons.delete_outline,
                            size: 18, color: theme.colorScheme.error),
                        child: Text(l10n(context).deleteProject),
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
                        tooltip: l10n(context).options,
                        icon: Icon(Icons.more_vert,
                            size: 18, color: theme.colorScheme.onSurfaceVariant),
                        onPressed: () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                          }
                        },
                      );
                    },
                  ),
                ],
              ),
              dense: true,
              onTap: onToggle,
            ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: isExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
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

class _ConnectionStatusIcon extends StatelessWidget {
  const _ConnectionStatusIcon();

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, ConnectionStatus>(
      (s) => s.connectionStatus,
    );
    final theme = Theme.of(context);
    final l = l10n(context);

    final (Color color, IconData icon, String label) = switch (status) {
      ConnectionStatus.connected =>
        (Colors.green, Icons.cloud_done, l.connected),
      ConnectionStatus.disconnected =>
        (theme.colorScheme.error, Icons.cloud_off, l.disconnected),
      ConnectionStatus.checking =>
        (theme.colorScheme.onSurfaceVariant, Icons.sync, l.checkingConnection),
    };

    final Widget indicator;
    if (status == ConnectionStatus.checking) {
      indicator = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );
    } else {
      indicator = Icon(icon, size: 16, color: color);
    }

    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: indicator,
      ),
    );
  }
}

class _NoProjects extends StatelessWidget {
  const _NoProjects();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n(context).noProjectsYet,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _NoThreads extends StatelessWidget {
  const _NoThreads();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        l10n(context).noThreadsYet,
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

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
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(1.0, 0.0),
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

Widget? _threadSubtitle(Thread thread, ThemeData theme) {
  final parts = <String>[];
  if (thread.branch != null && thread.branch!.isNotEmpty) {
    parts.add(thread.branch!);
  }
  if (thread.worktreePath != null && thread.worktreePath!.isNotEmpty) {
    parts.add(thread.worktreePath!.split('/').last);
  }
  if (parts.isEmpty) return null;
  return Text(
    parts.join('  '),
    style: theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);
    final topics = [
      (icon: Icons.person_outline, label: l.account),
      (icon: Icons.cloud_outlined, label: l.providers),
      (icon: Icons.devices_outlined, label: l.devices),
      (icon: Icons.palette_outlined, label: l.personalization),
      (icon: Icons.code_outlined, label: l.git),
      if (state.isOwner)
        (icon: Icons.manage_accounts_outlined, label: l.manage),
    ];

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        _SectionHeader(l.topics),
        for (var i = 0; i < topics.length; i++)
          Material(
            color: Colors.transparent,
            elevation: 0,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(topics[i].icon, size: 20),
              title: Row(
                children: [
                  Text(topics[i].label),
                  if (topics[i].label == l.manage) ...[
                    const SizedBox(width: 6),
                    const OwnerBadge(),
                  ],
                ],
              ),
              selected: i == state.settingsTopicIndex,
              selectedTileColor: theme.colorScheme.secondaryContainer,
              dense: true,
              onTap: () {
                state.setSettingsTopicIndex(i);
                Scaffold.of(context).closeDrawer();
              },
            ),
          ),
      ],
    );
  }
}

Future<bool> _confirm(BuildContext context, String message) async {
  final l = l10n(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l.delete),
        ),
      ],
    ),
  );
  return result ?? false;
}
