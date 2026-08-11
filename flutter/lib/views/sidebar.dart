import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

/// The sidebar: brand + new-thread button, thread list, user chip + menu.
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

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // Brand row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Icon(Icons.smart_toy_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child:
                      Text('Devinorium', style: theme.textTheme.titleMedium),
                ),
                IconButton.filled(
                  onPressed: () {
                    Scaffold.of(context).closeDrawer();
                    state.createNewThread();
                  },
                  icon: const Icon(Icons.add),
                  tooltip: 'New thread',
                ),
              ],
            ),
          ),
          // Thread list
          const Expanded(child: ThreadList()),
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
                      leadingIcon: const Icon(Icons.key_outlined),
                      child: const Text('Enable 2FA (TOTP)'),
                      onPressed: () => state.openTotpSetup(),
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

/// The thread list, organized by groups (with an "Ungrouped" section first).
class ThreadList extends StatelessWidget {
  const ThreadList({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final threads = state.threads;
    final groups = state.groups;
    final activeId = state.activeThreadId;

    if (threads.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No threads yet',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      );
    }

    final ungrouped = threads.where((t) => t.threadGroupId == null).toList();
    final grouped = groups
        .map((g) {
          final ts = threads.where((t) => t.threadGroupId == g.id).toList();
          return (g, ts);
        })
        .where((p) => p.$2.isNotEmpty)
        .toList();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        if (ungrouped.isNotEmpty) ...[
          const _SectionHeader('Ungrouped'),
          for (final t in ungrouped)
            _ThreadTile(thread: t, isActive: activeId == t.id),
          const SizedBox(height: 4),
        ],
        for (final (g, ts) in grouped) ...[
          _GroupHeader(group: g),
          for (final t in ts)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _ThreadTile(thread: t, isActive: activeId == t.id),
            ),
          const SizedBox(height: 4),
        ],
      ],
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

class _GroupHeader extends StatelessWidget {
  final ThreadGroup group;
  const _GroupHeader({required this.group});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.menu, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(group.name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500)),
          ),
          IconButton(
            tooltip: 'Delete group',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async {
              if (await _confirm(context,
                  'Delete this group? Threads will become ungrouped.')) {
                state.deleteThreadGroup(group.id);
              }
            },
          ),
        ],
      ),
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
