import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../servers/server_profile.dart';
import '../services/window_actions.dart';
import '../state/app_state.dart';
import '../theme/semantic_colors.dart';
import '../utils/thread_status.dart';
import '../widgets/message_view.dart';
import '../widgets/owner_badge.dart';
import '../widgets/provider_icons.dart';
import 'files_panel.dart';
import 'git_panel.dart';
import 'project_icon.dart';
import 'sidebar/link_merge_request_dialog.dart';
import 'settings/topics.dart';
import 'window_controls.dart';

part 'sidebar/project_thread_list.dart';
part 'sidebar/project_icon.dart';
part 'sidebar/project_expandable_tile.dart';
part 'sidebar/connection_status_icon.dart';
part 'sidebar/no_projects.dart';
part 'sidebar/no_threads.dart';
part 'sidebar/thread_tile.dart';
part 'sidebar/section_header.dart';
part 'sidebar/settings_nav.dart';
part 'sidebar/server_switcher.dart';

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

bool _isDesktop(BuildContext context) {
  if (kIsWeb) return false;
  return switch (Theme.of(context).platform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
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

({Color color, String label})? _threadStatus(
  BuildContext context,
  AppState state,
  Thread thread,
) {
  final l = l10n(context);
  final isRunning = state.runningThreadIds.contains(thread.id);
  final active = state.activeThreadDetail?.thread.id == thread.id;

  String? tag;
  if (isRunning || (active && state.sending)) {
    tag = 'running';
  } else if (active) {
    tag = activeThreadTag(
      sending: state.sending,
      messages: state.activeThreadDetail?.messages ?? const [],
      pendingPermissionRequest: state.pendingPermissionRequest,
      pendingAskRequest: state.pendingAskRequest,
      runStatus: state.lastRunStatus,
    );
  }

  if (tag == null) return null;

  final style = threadStatusStyle(Theme.of(context), tag);
  return switch (tag) {
    'running' ||
    'working' => (color: style.color, label: l.threadStatusWorking),
    'failed' => (color: style.color, label: l.threadStatusFailed),
    'needs approval' => (color: style.color, label: l.threadStatusApproval),
    'needs answer' => (color: style.color, label: l.threadStatusInput),
    _ => (color: style.color, label: l.threadStatusDone),
  };
}

/// The sidebar: projects, threads, and user menu.
/// When the user is on the Settings page, the sidebar shows settings topics
/// with a back button instead of the project/thread list.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    final appState = context.read<AppState>();
    if (appState.page == MainPage.settings) return false;

    // macOS keeps ⌘K because ⌘H collides with the system Hide shortcut.
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    if (isShift || isAlt) return false;

    final isControl = HardwareKeyboard.instance.isControlPressed;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final shortcut = isApple
        ? isMeta && !isControl && event.logicalKey == LogicalKeyboardKey.keyK
        : isControl && !isMeta && event.logicalKey == LogicalKeyboardKey.keyH;
    if (!shortcut) return false;

    if (_searchFocus.hasFocus) {
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
      return true;
    }

    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context != null) {
      final editable = focus!.context!
          .findAncestorWidgetOfExactType<EditableText>();
      if (editable != null) return false;
    }

    _searchFocus.requestFocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child:
          Selector<
            AppState,
            ({
              MainPage page,
              bool filesPanelOpen,
              bool gitPanelOpen,
              User? user,
              bool hasServer,
              bool localActive,
            })
          >(
            selector: (_, state) => (
              page: state.page,
              filesPanelOpen: state.filesPanelOpen,
              gitPanelOpen: state.gitPanelOpen,
              user: state.user,
              hasServer: state.multiServerState.hasAnyServer,
              localActive:
                  state.multiServerState.activeProfile?.isLocal ?? false,
            ),
            builder: (context, model, _) {
              final user = model.user;
              final username = user?.username ?? '';
              final avatar = username.isNotEmpty
                  ? username[0].toUpperCase()
                  : '?';
              final isSettings = model.page == MainPage.settings;
              final filesOpen = !isSettings && model.filesPanelOpen;
              final gitOpen = !isSettings && model.gitPanelOpen;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isSettings) const _AppTitle(),
                  if (isSettings) const _SettingsHeader(),
                  if (!isSettings) const _ModeSwitch(),
                  const _ServerSwitcher(),
                  if (!isSettings && !filesOpen && !gitOpen) ...[
                    _SearchField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                    ),
                    _ProjectsHeader(),
                  ],
                  Expanded(
                    child: isSettings
                        ? const _SettingsNav()
                        : gitOpen
                        ? const GitPanel()
                        : filesOpen
                        ? const FilesPanel()
                        : _ProjectThreadList(
                            searchQuery: _searchController.text,
                          ),
                  ),
                  if (model.hasServer)
                    _UserChip(
                      username: username,
                      avatar: avatar,
                      isLocal: model.localActive,
                    ),
                  const _ActivityBar(),
                ],
              );
            },
          ),
    );
  }
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar();

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({MainPage page, bool filesPanelOpen, bool gitPanelOpen})
    >(
      selector: (_, s) => (
        page: s.page,
        filesPanelOpen: s.filesPanelOpen,
        gitPanelOpen: s.gitPanelOpen,
      ),
      builder: (context, model, _) {
        final isSettings = model.page == MainPage.settings;
        final filesOpen = !isSettings && model.filesPanelOpen;
        final gitOpen = !isSettings && model.gitPanelOpen;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Row(
            children: [
              _ActivityIcon(
                icon: Icons.chat_bubble_outline,
                tooltip: l.chat,
                active: !isSettings && !filesOpen && !gitOpen,
                onPressed: () {
                  state.closeFilesPanel();
                  state.closeGitPanel();
                  state.setPage(MainPage.threads);
                },
              ),
              _ActivityIcon(
                icon: Icons.folder_outlined,
                tooltip: l.files,
                active: filesOpen,
                onPressed: () => unawaited(state.openFilesPanel()),
              ),
              _ActivityIcon(
                icon: Icons.account_tree_outlined,
                tooltip: l.git,
                active: gitOpen,
                onPressed: () => unawaited(state.openGitPanel()),
              ),
              const Spacer(),
              _ActivityIcon(
                icon: Icons.settings_outlined,
                tooltip: l.settings,
                active: isSettings,
                onPressed: () => state.setPage(MainPage.settings),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActivityIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  const _ActivityIcon({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: active ? theme.colorScheme.surfaceContainerHigh : null,
        foregroundColor: active
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

class _AppTitle extends StatefulWidget {
  const _AppTitle();

  @override
  State<_AppTitle> createState() => _AppTitleState();
}

class _AppTitleState extends State<_AppTitle> {
  late final Future<PackageInfo> _packageInfo;

  @override
  void initState() {
    super.initState();
    _packageInfo = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final isDesktop = _isDesktop(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isDesktop) ...[const WindowControls(), const SizedBox(width: 12)],
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => startWindowDragging(),
              onDoubleTap: toggleMaximize,
              child: FutureBuilder<PackageInfo>(
                future: _packageInfo,
                builder: (context, snapshot) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          l.appTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (snapshot.hasData) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            snapshot.data!.version,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, AppMode>(
      selector: (_, s) => s.appMode,
      builder: (context, appMode, _) {
        final isAgents = appMode == AppMode.agents;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor: isAgents
                        ? theme.colorScheme.surfaceContainerHigh
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: Text(l.agentsMode),
                  onPressed: () => state.setAppMode(AppMode.agents),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor: !isAgents
                        ? theme.colorScheme.surfaceContainerHigh
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.code, size: 18),
                  label: Text(l.editorMode),
                  onPressed: () => state.setAppMode(AppMode.editor),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);
    final isDesktop = _isDesktop(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isDesktop) ...[const WindowControls(), const SizedBox(width: 12)],
          IconButton(
            onPressed: () {
              Scaffold.of(context).closeDrawer();
              state.setPage(MainPage.threads);
            },
            icon: const Icon(Icons.arrow_back),
            tooltip: l.back,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => startWindowDragging(),
              onDoubleTap: toggleMaximize,
              child: Text(
                l.settings,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _SearchField({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final query = controller.text;
    final shortcutLabel = switch (theme.platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => l.searchKeyboardShortcut,
      _ => l.searchKeyboardShortcutNonMac,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Icon(
              Icons.search,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('sidebar_search'),
                controller: controller,
                focusNode: focusNode,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration.collapsed(
                  hintText: l.searchHint,
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (query.isEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    shortcutLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              )
            else
              IconButton(
                onPressed: () {
                  controller.clear();
                  focusNode.unfocus();
                },
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: l.clear,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProjectsHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l.projects.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            onPressed: () => state.openNewProjectDialog(),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            tooltip: l.newProject,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
          ),
          IconButton(
            onPressed: () => state.openCloneRepoDialog(),
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            tooltip: l.cloneRepo,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
          ),
        ],
      ),
    );
  }
}

class _UserChip extends StatelessWidget {
  final String username;
  final String avatar;

  /// True when the active profile is the bundled local server — there are
  /// no credentials to sign out of, so the menu hides the sign-out item.
  final bool isLocal;

  const _UserChip({
    required this.username,
    required this.avatar,
    this.isLocal = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
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
                radius: 14,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                child: Text(avatar),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  username,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
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
                  if (!isLocal)
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
