part of '../sidebar.dart';

/// The compact sidebar: a narrow icon rail where every control stays
/// reachable through tooltipped icons. Content that needs width (search,
/// file/git trees) expands the sidebar; thread lists open as flyout menus
/// anchored to their project icon.
class _CompactRail extends StatefulWidget {
  /// Expands the sidebar and focuses the rebuilt search field. Owned by
  /// the parent [Sidebar] state so it stays valid while the rail unmounts.
  final VoidCallback onRevealSearch;

  const _CompactRail({required this.onRevealSearch});

  @override
  State<_CompactRail> createState() => _CompactRailState();
}

class _CompactRailState extends State<_CompactRail> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // The expanded list polls every 5s for running threads; the rail shows
    // the same activity badges, so it keeps polling while the list is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshRunningThreads();
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) context.read<AppState>().refreshRunningThreads();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();
    final isDesktop = _isDesktop(context);
    final shortcutLabel = switch (theme.platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => l.sidebarToggleShortcut,
      _ => l.sidebarToggleShortcutNonMac,
    };

    return Selector<
      AppState,
      ({
        MainPage page,
        AppMode appMode,
        bool filesPanelOpen,
        bool gitPanelOpen,
        User? user,
        bool hasServer,
        bool localActive,
        List<Project> projects,
        List<Thread> threads,
        int? activeProjectId,
        String? activeThreadId,
        Set<String> runningThreadIds,
        int? selectedGroupId,
        List<ProjectGroup> groups,
        bool groupsUnsupported,
        bool hasMoreProjects,
        bool isLoadingMoreProjects,
      })
    >(
      selector: (_, s) => (
        page: s.page,
        appMode: s.appMode,
        filesPanelOpen: s.filesPanelOpen,
        gitPanelOpen: s.gitPanelOpen,
        user: s.user,
        hasServer: s.multiServerState.hasAnyServer,
        localActive: s.multiServerState.activeProfile?.isLocal ?? false,
        projects: s.projects,
        threads: s.threads,
        activeProjectId: s.activeProjectId,
        activeThreadId: s.activeThreadId,
        runningThreadIds: s.runningThreadIds,
        selectedGroupId: s.selectedProjectGroupId,
        groups: s.projectGroups,
        groupsUnsupported: s.projectGroupsUnsupported,
        hasMoreProjects: s.hasMoreProjects,
        isLoadingMoreProjects: s.isLoadingMoreProjects,
      ),
      builder: (context, model, _) {
        final isSettings = model.page == MainPage.settings;
        final filesOpen = !isSettings && model.filesPanelOpen;
        final gitOpen = !isSettings && model.gitPanelOpen;

        // The expanded list applies the group filter; the rail shows the
        // same projects.
        final groupId = model.groups.any((g) => g.id == model.selectedGroupId)
            ? model.selectedGroupId
            : null;
        final projects = groupId == null
            ? model.projects
            : model.projects.where((p) => p.groupId == groupId).toList();

        final threadsByProject = <int, List<Thread>>{};
        for (final t in model.threads) {
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

        final user = model.user;
        final username = user?.username ?? '';
        final avatar = username.isNotEmpty ? username[0].toUpperCase() : '?';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => startWindowDragging(),
              onDoubleTap: toggleMaximize,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                child: Column(
                  children: [
                    if (isDesktop) ...[
                      const WindowControls(direction: Axis.vertical),
                      const SizedBox(height: 8),
                    ],
                    if (isSettings)
                      IconButton(
                        onPressed: () {
                          state.closeSidebar();
                          state.setPage(MainPage.threads);
                        },
                        icon: const Icon(Icons.arrow_back, size: 20),
                        tooltip: l.back,
                        visualDensity: VisualDensity.compact,
                      )
                    else
                      Tooltip(
                        message: l.appTitle,
                        child: Image.asset(
                          'assets/icon.png',
                          width: 28,
                          height: 28,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!isSettings) ...[
              _ActivityIcon(
                icon: Icons.smart_toy_outlined,
                tooltip: l.agentsMode,
                active: model.appMode == AppMode.agents,
                onPressed: () => state.setAppMode(AppMode.agents),
              ),
              _ActivityIcon(
                icon: Icons.code,
                tooltip: l.editorMode,
                active: model.appMode == AppMode.editor,
                onPressed: () => state.setAppMode(AppMode.editor),
              ),
            ],
            const _ServerSwitcher(compact: true),
            if (!isSettings) ...[
              _ActivityIcon(
                key: const Key('rail_search'),
                icon: Icons.search,
                tooltip: l.search,
                active: false,
                onPressed: widget.onRevealSearch,
              ),
              if (!model.groupsUnsupported)
                _RailGroupFilter(groups: model.groups, selectedId: groupId),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Divider(height: 1, indent: 14, endIndent: 14),
            ),
            Expanded(
              child: isSettings
                  ? const _SettingsNav(compact: true)
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        if (projects.isEmpty)
                          Tooltip(
                            message: groupId == null
                                ? l.noProjectsYet
                                : l.groupEmpty,
                            child: Icon(
                              Icons.folder_off_outlined,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        for (final p in projects)
                          Center(
                            child: _RailProject(
                              key: Key('rail_project_${p.id}'),
                              project: p,
                              threads: threadsByProject[p.id] ?? const [],
                              active: p.id == model.activeProjectId,
                              activeThreadId: model.activeThreadId,
                              hasRunning:
                                  (threadsByProject[p.id] ?? const <Thread>[])
                                      .any(
                                        (t) => model.runningThreadIds.contains(
                                          t.id,
                                        ),
                                      ),
                            ),
                          ),
                        if (model.hasMoreProjects)
                          _ActivityIcon(
                            icon: Icons.more_horiz,
                            tooltip: l.loadMore,
                            active: false,
                            onPressed: model.isLoadingMoreProjects
                                ? null
                                : state.loadMoreProjects,
                          ),
                      ],
                    ),
            ),
            if (!isSettings)
              _ActivityIcon(
                key: const Key('rail_add_project'),
                icon: Icons.add,
                tooltip: l.addProject,
                active: false,
                onPressed: state.openAddProjectDialog,
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Divider(height: 1, indent: 14, endIndent: 14),
            ),
            if (model.hasServer)
              _RailUserChip(
                username: username,
                avatar: avatar,
                isLocal: model.localActive,
              ),
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
            _ActivityIcon(
              icon: Icons.settings_outlined,
              tooltip: l.settings,
              active: isSettings,
              onPressed: () => state.setPage(MainPage.settings),
            ),
            _ActivityIcon(
              key: const Key('sidebar_compact_toggle'),
              icon: Icons.keyboard_double_arrow_right,
              tooltip: '${l.expandSidebar} ($shortcutLabel)',
              active: false,
              onPressed: () => state.setSidebarCompact(false),
            ),
            const SizedBox(height: 10),
          ],
        );
      },
    );
  }
}

class _RailProject extends StatelessWidget {
  final Project project;
  final List<Thread> threads;
  final bool active;
  final String? activeThreadId;
  final bool hasRunning;

  /// Menus stay shallow: past this many loaded threads the flyout tells the
  /// user to expand for the full list instead of scrolling forever.
  static const int _maxMenuThreads = 8;

  const _RailProject({
    super.key,
    required this.project,
    required this.threads,
    required this.active,
    required this.activeThreadId,
    required this.hasRunning,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();
    final color = _projectColor(project.name);

    final visible = threads.take(_maxMenuThreads).toList();
    final hiddenCount = threads.length - visible.length;
    final hasMore = state.hasMoreProjectThreads(project.id);
    final loadingMore = state.isLoadingMoreProjectThreads(project.id);

    return MenuAnchor(
      onClose: () => _clearMenuFocus(context),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.add, size: 18),
          onPressed: () => state.createNewThread(projectId: project.id),
          child: Text(
            l.newThreadIn(project.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (threads.isNotEmpty) const Divider(height: 1),
        for (final t in visible)
          MenuItemButton(
            leadingIcon: ProviderIcon(
              providerId: t.providerId,
              size: 16,
              semanticLabel: providerName(t.providerId),
            ),
            trailingIcon: _RailThreadStatus(
              thread: t,
              active: t.id == activeThreadId,
            ),
            onPressed: () => state.openThread(t.id),
            child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        if (threads.isEmpty)
          MenuItemButton(onPressed: null, child: Text(l.noThreadsYet)),
        if (hiddenCount > 0)
          MenuItemButton(
            leadingIcon: const Icon(Icons.unfold_more, size: 18),
            onPressed: state.expandSidebar,
            child: Text(l.showMoreThreads(hiddenCount)),
          )
        else if (hasMore)
          MenuItemButton(
            leadingIcon: const Icon(Icons.more_horiz, size: 18),
            onPressed: loadingMore
                ? null
                : () => unawaited(state.loadMoreProjectThreads(project.id)),
            child: Text(l.loadMore),
          ),
        const Divider(height: 1),
        SubmenuButton(
          leadingIcon: const Icon(Icons.more_vert, size: 18),
          menuChildren: _projectMenuItems(context, state, project),
          child: Text(l.options),
        ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: '${project.name}\n${project.path}',
          child: Material(
            color: active
                ? theme.colorScheme.surfaceContainerHigh
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Stack(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(8),
                        border: project.pinned
                            ? Border(
                                left: BorderSide(
                                  color: theme.colorScheme.primary,
                                  width: 3,
                                ),
                              )
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: _ProjectIcon(project: project, color: color),
                    ),
                    if (hasRunning)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          key: Key('rail_running_${project.id}'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.surfaceContainerLowest,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Group filter as a rail icon: same entries as the expanded dropdown.
class _RailGroupFilter extends StatelessWidget {
  final List<ProjectGroup> groups;
  final int? selectedId;

  const _RailGroupFilter({required this.groups, required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();
    final selected = groups
        .where((g) => g.id == selectedId)
        .map((g) => g.name)
        .firstOrNull;

    return MenuAnchor(
      onClose: () => _clearMenuFocus(context),
      menuChildren: _groupFilterItems(context, state, groups, selectedId),
      builder: (context, controller, child) {
        return IconButton(
          key: const Key('rail_group_filter'),
          tooltip: '${l.projectGroupMenu}: ${selected ?? l.groupFilterAll}',
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            backgroundColor: selected != null
                ? theme.colorScheme.surfaceContainerHigh
                : null,
            foregroundColor: theme.colorScheme.onSurfaceVariant,
          ),
          icon: const Icon(Icons.filter_list, size: 20),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
    );
  }
}

/// Trailing markers for a thread inside a rail flyout: a colored status dot
/// for attention/running states plus a check on the open thread.
class _RailThreadStatus extends StatelessWidget {
  final Thread thread;
  final bool active;

  const _RailThreadStatus({required this.thread, required this.active});

  @override
  Widget build(BuildContext context) {
    final status = _threadStatus(context, context.read<AppState>(), thread);
    if (status == null && !active) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null)
          Tooltip(
            message: status.label,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: status.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        if (active) ...[
          if (status != null) const SizedBox(width: 4),
          const Icon(Icons.check, size: 16),
        ],
      ],
    );
  }
}

class _RailUserChip extends StatelessWidget {
  final String username;
  final String avatar;
  final bool isLocal;

  const _RailUserChip({
    required this.username,
    required this.avatar,
    required this.isLocal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ConnectionStatus>(
      selector: (_, s) => s.connectionStatus,
      builder: (context, status, _) {
        final style = _connectionStatusStyle(context, status);
        final label = username.isNotEmpty
            ? '$username · ${style.label}'
            : l.menu;
        return MenuAnchor(
          onClose: () => _clearMenuFocus(context),
          menuChildren: _userMenuItems(context, state, isLocal: isLocal),
          builder: (context, controller, child) {
            return IconButton(
              key: const Key('rail_user_menu'),
              tooltip: label,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              icon: Stack(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    child: Text(avatar),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: style.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surfaceContainerLowest,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
