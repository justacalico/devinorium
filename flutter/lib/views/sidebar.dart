import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/owner_badge.dart';
import 'project_icon.dart';

part 'sidebar/project_thread_list.dart';
part 'sidebar/project_icon.dart';
part 'sidebar/project_expandable_tile.dart';
part 'sidebar/connection_status_icon.dart';
part 'sidebar/no_projects.dart';
part 'sidebar/no_threads.dart';
part 'sidebar/thread_tile.dart';
part 'sidebar/section_header.dart';
part 'sidebar/settings_nav.dart';

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
                if (!isSettings) ...[
                  IconButton(
                    onPressed: () => state.openNewProjectDialog(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: l10n(context).newProject,
                  ),
                  IconButton(
                    onPressed: () => state.openCloneRepoDialog(),
                    icon: const Icon(Icons.cloud_download_outlined),
                    tooltip: l10n(context).cloneRepo,
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

Widget? _threadSubtitle(AppState state, Thread thread, ThemeData theme) {
  final parts = <String>[];
  final repo = state.gitRepoInfo(thread.projectId);

  if (thread.worktreePath != null && thread.worktreePath!.isNotEmpty) {
    final worktrees = state.gitWorktrees(thread.projectId);
    GitWorktree? active;
    for (final w in worktrees) {
      if (w.path == thread.worktreePath) {
        active = w;
        break;
      }
    }
    final branch = active?.branch ??
        active?.head ??
        repo?.branch ??
        thread.branch ??
        '';
    if (branch.isNotEmpty) parts.add(branch);
    parts.add(thread.worktreePath!.split('/').last);
  } else {
    final branch = repo?.branch ?? thread.branch ?? '';
    if (branch.isNotEmpty) parts.add(branch);
  }

  if (parts.isEmpty) return null;
  return Text(
    parts.join('  '),
    style: theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
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
