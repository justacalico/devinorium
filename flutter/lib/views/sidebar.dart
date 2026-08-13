import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

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

String _timeAgo(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final now = DateTime.now().toUtc();
  final diff = now.difference(dt.toUtc());
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
  return '${(diff.inDays / 365).floor()}y ago';
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
                    tooltip: 'Back',
                  )
                else
                  Icon(Icons.folder_outlined,
                      color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isSettings ? 'Settings' : 'Projects',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (!isSettings)
                  IconButton(
                    onPressed: () => state.openNewProjectDialog(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'New project',
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
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                MenuAnchor(
                  menuChildren: [
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.settings_outlined),
                      child: const Text('Settings'),
                      onPressed: () {
                        state.setPage(MainPage.settings);
                        state.setUserMenuOpen(false);
                      },
                    ),
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.logout),
                      child: const Text('Sign out'),
                      onPressed: () => state.logout(),
                    ),
                  ],
                  builder: (context, controller, child) {
                    return IconButton(
                      tooltip: 'Menu',
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects;
    final activeProjectId = state.activeProjectId;
    final threads = state.threads;
    final activeThreadId = state.activeThreadId;

    // Auto-expand when the active project changes.
    if (activeProjectId != _lastActiveProjectId) {
      _lastActiveProjectId = activeProjectId;
      if (activeProjectId != null) {
        _expandedIds.add(activeProjectId);
      }
    }

    if (projects.isEmpty) {
      return const _NoProjects();
    }

    final threadsByProject = <int, List<Thread>>{};
    for (final t in threads) {
      if (t.projectId != 0) {
        threadsByProject.putIfAbsent(t.projectId, () => []).add(t);
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        for (final p in projects)
          _ProjectExpandableTile(
            project: p,
            threads: threadsByProject[p.id] ?? [],
            isActive: activeProjectId == p.id,
            isExpanded: _expandedIds.contains(p.id),
            activeThreadId: activeThreadId,
            onToggle: () => _onToggle(p.id),
            onNewThread: () {
              Scaffold.of(context).closeDrawer();
              state.createNewThread(projectId: p.id);
            },
            onThreadTap: (id) => state.openThread(id),
          ),
      ],
    );
  }

  void _onToggle(int id) {
    final state = context.read<AppState>();
    if (state.activeProjectId != id) {
      state.selectProject(id);
    } else {
      setState(() {
        if (_expandedIds.contains(id)) {
          _expandedIds.remove(id);
        } else {
          _expandedIds.add(id);
        }
      });
    }
  }
}

class _ProjectExpandableTile extends StatelessWidget {
  final Project project;
  final List<Thread> threads;
  final bool isActive;
  final bool isExpanded;
  final String? activeThreadId;
  final VoidCallback onToggle;
  final VoidCallback? onNewThread;
  final ValueChanged<String> onThreadTap;

  const _ProjectExpandableTile({
    required this.project,
    required this.threads,
    required this.isActive,
    required this.isExpanded,
    this.activeThreadId,
    required this.onToggle,
    this.onNewThread,
    required this.onThreadTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _projectColor(project.name);
    final borderColor = isActive
        ? theme.colorScheme.primary
        : Colors.transparent;
    final bgColor = isActive
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
        : null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(color: borderColor, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: color,
              child: Text(
                project.name.isNotEmpty ? project.name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
            title: Text(
              project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
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
                    tooltip: 'New thread in ${project.name}',
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: onNewThread,
                  ),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.keyboard_arrow_down, size: 20),
                ),
              ],
            ),
            dense: true,
            onTap: onToggle,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: isExpanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (threads.isEmpty)
                        const _NoThreads()
                      else
                        for (final t in threads)
                          _ThreadTile(
                            thread: t,
                            isActive: activeThreadId == t.id,
                            onTap: () => onThreadTap(t.id),
                          ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
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
          'No projects yet.\nCreate one to get started.',
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
        'No threads yet',
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  final Thread thread;
  final bool isActive;
  final VoidCallback onTap;

  const _ThreadTile({
    required this.thread,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final time = _timeAgo(thread.updatedAt);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      decoration: BoxDecoration(
        border: isActive
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: const Icon(Icons.chat_outlined, size: 18),
        title: Text(
          thread.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (time.isNotEmpty)
              Text(
                time,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
              onPressed: () async {
                if (await _confirm(
                    context, 'Delete this thread? This cannot be undone.')) {
                  state.deleteThread(thread.id);
                }
              },
            ),
          ],
        ),
        selected: isActive,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        shape: const StadiumBorder(),
        dense: true,
        onTap: () {
          // Close the drawer if open (mobile layout).
          Scaffold.of(context).closeDrawer();
          onTap();
        },
      ),
    );
  }
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
    final theme = Theme.of(context);
    final topics = [
      (icon: Icons.person_outline, label: 'Account'),
    ];

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        const _SectionHeader('Topics'),
        for (final t in topics)
          ListTile(
            leading: Icon(t.icon, size: 20),
            title: Text(t.label),
            selected: t.label == 'Account',
            selectedTileColor: theme.colorScheme.secondaryContainer,
            shape: const StadiumBorder(),
            dense: true,
            onTap: () => Scaffold.of(context).closeDrawer(),
          ),
      ],
    );
  }
}

Future<bool> _confirm(BuildContext context, String message) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}
