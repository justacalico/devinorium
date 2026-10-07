import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

part 'branch_toolbar_items.dart';

const _kCreateBranch = '__create_branch__';

typedef _BranchToolbarModel = ({
  int? projectId,
  String? threadId,
  bool sending,
  Thread? thread,
  GitRepoInfo? repo,
  List<GitBranch>? branches,
  List<GitWorktree>? worktrees,
  String envMode,
});

/// Compact Git branch and worktree controls that live beneath the chat
/// composer, similar to t3code. Branch display tracks the repo's current
/// checkout (or the checked-out branch of the selected worktree) so the UI
/// never claims the thread is on a branch it is not actually on.
class BranchToolbar extends StatefulWidget {
  const BranchToolbar({super.key});

  @override
  State<BranchToolbar> createState() => _BranchToolbarState();
}

class _BranchToolbarState extends State<BranchToolbar> {
  bool _pulling = false;
  bool _pushing = false;

  int? _lastProjectId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    final projectId = state.activeProjectId;
    if (projectId != null && projectId != _lastProjectId) {
      _lastProjectId = projectId;
      unawaited(state.loadGitBranchData(projectId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, _BranchToolbarModel>(
      selector: (_, s) {
        final projectId = s.activeProjectId;
        final threadId = s.activeThreadId;
        final thread = s.activeThreadDetail?.thread;
        final repo = projectId != null ? s.gitRepoInfo(projectId) : null;
        final branches = projectId != null ? s.gitBranches(projectId) : null;
        final worktrees = projectId != null ? s.gitWorktrees(projectId) : null;
        return (
          projectId: projectId,
          threadId: threadId,
          sending: s.sending,
          thread: thread,
          repo: repo,
          branches: branches,
          worktrees: worktrees,
          envMode: thread?.envMode ?? 'local',
        );
      },
      builder: (context, model, _) {
        final projectId = model.projectId;
        final threadId = model.threadId;
        if (projectId == null || threadId == null || threadId.isEmpty) {
          return const SizedBox.shrink();
        }

        final repo = model.repo;
        if (repo == null || !repo.isRepo || repo.branch.isEmpty) {
          return const SizedBox.shrink();
        }

        final thread = model.thread;
        final branches = model.branches ?? const [];
        final worktrees = model.worktrees ?? const [];
        final mainWorktreePath = repo.worktreePath.isNotEmpty
            ? repo.worktreePath
            : repo.toplevel;
        final activeWorktreePath = thread?.worktreePath;
        final activeWorktree = activeWorktreePath != null
            ? _findWorktree(worktrees, activeWorktreePath)
            : null;
        final isOnMainWorktree =
            model.envMode != 'worktree' ||
            activeWorktreePath == null ||
            activeWorktreePath.isEmpty ||
            activeWorktreePath == mainWorktreePath ||
            (activeWorktree != null && activeWorktree.isMain);
        final worktreeBranch = activeWorktree?.branch;
        final effectiveBranch = isOnMainWorktree
            ? repo.branch
            : (worktreeBranch?.isNotEmpty == true
                  ? worktreeBranch!
                  : (activeWorktree?.head ?? repo.branch));

        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 420;
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: _buildBranchButton(
                    state: state,
                    projectId: projectId,
                    threadId: threadId,
                    repo: repo,
                    branches: branches,
                    effectiveBranch: effectiveBranch,
                    isOnMainWorktree: isOnMainWorktree,
                    sending: model.sending,
                    compact: compact,
                    theme: theme,
                    l: l,
                  ),
                ),
                if (repo.behind > 0) ...[
                  const SizedBox(width: 2),
                  _HeaderAction(
                    label: '↓${repo.behind}',
                    tooltip: l.pull,
                    loading: _pulling,
                    onPressed: isOnMainWorktree && !model.sending
                        ? () => _pull(state, projectId)
                        : null,
                  ),
                ],
                if (repo.ahead > 0) ...[
                  const SizedBox(width: 2),
                  _HeaderAction(
                    label: '↑${repo.ahead}',
                    tooltip: l.push,
                    loading: _pushing,
                    onPressed: isOnMainWorktree && !model.sending
                        ? () => _push(state, projectId)
                        : null,
                  ),
                ],
                const SizedBox(width: 8),
                Flexible(
                  child: _buildEnvModeButton(
                    state: state,
                    threadId: threadId,
                    envMode: model.envMode,
                    sending: model.sending,
                    compact: compact,
                    theme: theme,
                    l: l,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  GitBranch? _findBranch(List<GitBranch> branches, String name) {
    for (final b in branches) {
      if (b.name == name) return b;
    }
    return null;
  }

  GitWorktree? _findWorktree(List<GitWorktree> worktrees, String path) {
    for (final w in worktrees) {
      if (w.path == path) return w;
    }
    return null;
  }

  Widget _buildEnvModeButton({
    required AppState state,
    required String threadId,
    required String envMode,
    required bool sending,
    required bool compact,
    required ThemeData theme,
    required AppLocalizations l,
  }) {
    final active = envMode == 'worktree';
    final foreground = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final label = active ? l.worktreeModeShort : l.localModeShort;

    return PopupMenuButton<String>(
      key: const Key('branch_toolbar_env_mode'),
      enabled: !sending,
      tooltip: l.envModeTooltip,
      offset: const Offset(0, -4),
      onSelected: (value) => _onEnvModeMenuSelected(state, threadId, value),
      itemBuilder: (context) =>
          _buildEnvModeMenuItems(currentMode: envMode, l: l, theme: theme),
      child: _ToolbarButton(
        icon: active ? Icons.fork_right : Icons.terminal,
        label: label,
        compact: compact,
        foreground: foreground,
        theme: theme,
      ),
    );
  }

  List<PopupMenuEntry<String>> _buildEnvModeMenuItems({
    required String currentMode,
    required AppLocalizations l,
    required ThemeData theme,
  }) {
    return [
      PopupMenuItem<String>(
        enabled: false,
        child: Text(
          l.envModeTooltip,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const PopupMenuDivider(height: 8),
      CheckedPopupMenuItem(
        value: 'local',
        checked: currentMode == 'local',
        child: Text(l.localMode),
      ),
      CheckedPopupMenuItem(
        value: 'worktree',
        checked: currentMode == 'worktree',
        child: Text(l.worktreeMode),
      ),
    ];
  }

  Future<void> _onEnvModeMenuSelected(
    AppState state,
    String threadId,
    String value,
  ) async {
    if (value != 'local' && value != 'worktree') return;
    await state.setThreadEnvMode(threadId, value);
  }

  Widget _buildBranchButton({
    required AppState state,
    required int projectId,
    required String threadId,
    required GitRepoInfo repo,
    required List<GitBranch> branches,
    required String effectiveBranch,
    required bool isOnMainWorktree,
    required bool sending,
    required bool compact,
    required ThemeData theme,
    required AppLocalizations l,
  }) {
    final enabled = isOnMainWorktree && !sending;
    final foreground = theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: enabled ? l.gitBranches : l.worktreeBranchLocked,
      child: PopupMenuButton<String?>(
        key: const Key('branch_toolbar_branch'),
        enabled: enabled,
        tooltip: '',
        offset: const Offset(0, -4),
        onSelected: (value) =>
            _onBranchMenuSelected(state, projectId, threadId, branches, value),
        itemBuilder: (context) => _buildBranchMenuItems(
          branches: branches,
          currentBranch: effectiveBranch,
          l: l,
          theme: theme,
        ),
        child: _ToolbarButton(
          icon: Icons.call_split,
          label: effectiveBranch,
          compact: compact,
          foreground: foreground,
          theme: theme,
        ),
      ),
    );
  }

  List<PopupMenuEntry<String?>> _buildBranchMenuItems({
    required List<GitBranch> branches,
    required String currentBranch,
    required AppLocalizations l,
    required ThemeData theme,
  }) {
    final items = <PopupMenuEntry<String?>>[];
    items.add(
      PopupMenuItem<String?>(
        enabled: false,
        child: Text(
          l.gitBranches,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    items.add(const PopupMenuDivider(height: 8));

    final defaultIndex = branches.indexWhere((b) => b.isDefault);
    final defaultBranch = defaultIndex >= 0 ? branches[defaultIndex] : null;
    final others = branches.where((b) => !b.isDefault).toList();

    void addBranch(GitBranch b) {
      final isCurrent = b.name == currentBranch;
      items.add(
        CheckedPopupMenuItem(
          value: b.name,
          checked: isCurrent,
          child: _BranchItem(branch: b, isCurrent: isCurrent, theme: theme),
        ),
      );
    }

    if (defaultBranch != null) addBranch(defaultBranch);
    for (final b in others) {
      addBranch(b);
    }

    if (branches.isEmpty && currentBranch.isNotEmpty) {
      items.add(
        PopupMenuItem<String?>(
          value: currentBranch,
          enabled: false,
          child: _BranchItem(
            name: currentBranch,
            isCurrent: true,
            theme: theme,
          ),
        ),
      );
    }

    items.add(const PopupMenuDivider(height: 8));
    items.add(
      PopupMenuItem<String?>(
        value: _kCreateBranch,
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(l.createBranch),
          ],
        ),
      ),
    );
    return items;
  }

  Future<void> _onBranchMenuSelected(
    AppState state,
    int projectId,
    String threadId,
    List<GitBranch> branches,
    String? value,
  ) async {
    if (value == null) return;
    if (value == _kCreateBranch) {
      if (!mounted) return;
      await _showCreateBranchDialog(
        context,
        state,
        projectId,
        threadId,
        branches,
      );
      return;
    }
    final branch = _findBranch(branches, value);
    if (branch == null) return;
    final ok = await state.gitCheckout(
      projectId,
      branch.name,
      track: branch.isRemote,
    );
    if (!ok) return;
    final repo = state.gitRepoInfo(projectId);
    final current = repo?.branch ?? branch.name;
    if (current.isNotEmpty) {
      await state.setThreadGit(threadId, branch: current);
    }
  }

  Future<void> _showCreateBranchDialog(
    BuildContext context,
    AppState state,
    int projectId,
    String threadId,
    List<GitBranch> branches,
  ) async {
    final l = l10n(context);
    final branchNames = branches.map((b) => b.name).toList();
    String? base;
    var name = '';
    var submitting = false;
    var error = '';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> submit(bool switchBranch) async {
              if (name.trim().isEmpty) return;
              setState(() {
                submitting = true;
                error = '';
              });
              final ok = await state.gitCreateBranch(
                projectId,
                name.trim(),
                base: base?.trim(),
                switchBranch: switchBranch,
              );
              if (!dialogContext.mounted) return;
              if (ok) {
                Navigator.of(dialogContext).pop();
                if (switchBranch) {
                  final currentRepo = state.gitRepoInfo(projectId);
                  final current = currentRepo?.branch ?? name;
                  if (current.isNotEmpty) {
                    await state.setThreadGit(threadId, branch: current);
                  }
                }
                return;
              }
              setState(() {
                submitting = false;
                error = state.globalError;
              });
            }

            return AlertDialog(
              scrollable: true,
              title: Text(l.createBranch),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      enabled: !submitting,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: l.branchName,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => name = v),
                    ),
                    const SizedBox(height: 16),
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: l.baseBranchOptional,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          isDense: true,
                          value: base,
                          hint: Text(l.none),
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(l.none),
                            ),
                            ...branchNames.map(
                              (name) => DropdownMenuItem<String?>(
                                value: name,
                                child: Text(name),
                              ),
                            ),
                          ],
                          onChanged: submitting
                              ? null
                              : (v) => setState(() => base = v),
                        ),
                      ),
                    ),
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(l.close),
                ),
                OutlinedButton(
                  onPressed: submitting || name.trim().isEmpty
                      ? null
                      : () => submit(false),
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.createBranch),
                ),
                FilledButton(
                  onPressed: submitting || name.trim().isEmpty
                      ? null
                      : () => submit(true),
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.createAndSwitchBranch),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _pull(AppState state, int projectId) async {
    setState(() => _pulling = true);
    try {
      await state.gitPull(projectId);
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  Future<void> _push(AppState state, int projectId) async {
    setState(() => _pushing = true);
    try {
      await state.gitPush(projectId);
    } finally {
      if (mounted) setState(() => _pushing = false);
    }
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool compact;
  final Color? foreground;
  final ThemeData theme;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.compact,
    required this.foreground,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground?.withValues(alpha: 0.85)),
          if (!compact) ...[
            const SizedBox(width: 4),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 2),
          Icon(
            Icons.arrow_drop_down,
            size: 16,
            color: foreground?.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }
}
