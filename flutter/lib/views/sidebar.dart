import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

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
                if (!isSettings) ...[
                  IconButton(
                    onPressed: () => state.openNewProjectDialog(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'New project',
                  ),
                  IconButton.filled(
                    onPressed: state.activeProjectId == null
                        ? null
                        : () {
                            Scaffold.of(context).closeDrawer();
                            state.createNewThread();
                          },
                    icon: const Icon(Icons.add),
                    tooltip: 'New thread',
                  ),
                ],
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
                      leadingIcon: const Icon(Icons.mail_outline),
                      child: const Text('Invites'),
                      onPressed: () => state.openInvites(),
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

/// A combined list of projects with the selected project expanded to show its threads.
class _ProjectThreadList extends StatelessWidget {
  const _ProjectThreadList();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects;
    final activeProjectId = state.activeProjectId;
    final threads = state.threads;
    final activeThreadId = state.activeThreadId;

    final children = <Widget>[];

    children.add(_AllProjectsTile(
      selected: activeProjectId == null,
      onTap: () => context.read<AppState>().selectAllProjects(),
    ));

    if (activeProjectId == null) {
      children.add(const _SectionHeader('Threads'));
      if (threads.isEmpty) {
        children.add(const _NoThreads());
      } else {
        for (final t in threads) {
          children.add(_ThreadTile(thread: t, isActive: activeThreadId == t.id));
        }
      }
      children.add(const SizedBox(height: 8));
      children.add(const _SectionHeader('Projects'));
    }

    for (final p in projects) {
      final selected = activeProjectId == p.id;
      children.add(_ProjectTile(
        project: p,
        selected: selected,
        onTap: () => context.read<AppState>().selectProject(p.id),
      ));
      if (selected) {
        children.add(const _SectionHeader('Threads'));
        if (threads.isEmpty) {
          children.add(const _NoThreads());
        } else {
          for (final t in threads) {
            children.add(_ThreadTile(thread: t, isActive: activeThreadId == t.id));
          }
        }
        children.add(const SizedBox(height: 8));
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: children,
    );
  }
}

class _AllProjectsTile extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _AllProjectsTile({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.all_inbox, color: theme.colorScheme.primary, size: 20),
      title: Text('All projects', style: theme.textTheme.bodyMedium),
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      shape: const StadiumBorder(),
      dense: true,
      onTap: onTap,
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final bool selected;
  final VoidCallback onTap;
  const _ProjectTile({
    required this.project,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.work_outline, size: 20),
      title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      shape: const StadiumBorder(),
      dense: true,
      onTap: onTap,
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

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  final Thread thread;
  final bool isActive;
  const _ThreadTile({required this.thread, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.chat_outlined, size: 20),
      title: Text(thread.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: isActive,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      shape: const StadiumBorder(),
      dense: true,
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: () async {
          if (await _confirm(
              context, 'Delete this thread? This cannot be undone.')) {
            state.deleteThread(thread.id);
          }
        },
      ),
      onTap: () {
        // Close the drawer if open (mobile layout).
        Scaffold.of(context).closeDrawer();
        state.openThread(thread.id);
      },
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
      (icon: Icons.notifications_outlined, label: 'Notifications'),
      (icon: Icons.palette_outlined, label: 'Appearance'),
      (icon: Icons.model_training_outlined, label: 'Models'),
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
            onTap: () {
              // Currently only Account is implemented; future topics will
              // scroll to or switch the corresponding settings section.
              Scaffold.of(context).closeDrawer();
            },
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
