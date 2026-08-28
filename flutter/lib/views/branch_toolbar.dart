import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

part 'branch_toolbar_items.dart';

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
  final _branchNameController = TextEditingController();
  final _worktreeNameController = TextEditingController();

  bool _creatingBranch = false;
  bool _creatingWorktree = false;
  bool _submitting = false;
  bool _pulling = false;
  bool _pushing = false;

  String? _createBranchBase;
  String? _createWorktreeBase;
  bool _createWorktreeNewBranch = false;

  int? _lastProjectId;

  @override
  void dispose() {
    _branchNameController.dispose();
    _worktreeNameController.dispose();
    super.dispose();
  }

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
    final state = context.watch<AppState>();
    final projectId = state.activeProjectId;
    final threadId = state.activeThreadId;
    if (projectId == null || threadId == null || threadId.isEmpty) {
      return const SizedBox.shrink();
    }

    final repo = state.gitRepoInfo(projectId);
    if (repo == null || !repo.isRepo || repo.branch.isEmpty) {
      return const SizedBox.shrink();
    }

    final thread = state.activeThreadDetail?.thread;
    final branches = state.gitBranches(projectId);
    final worktrees = state.gitWorktrees(projectId);
    final mainWorktreePath =
        repo.worktreePath.isNotEmpty ? repo.worktreePath : repo.toplevel;
    final activeWorktreePath = thread?.worktreePath;
    final activeWorktree = activeWorktreePath != null
        ? _findWorktree(worktrees, activeWorktreePath)
        : null;
    final isOnMainWorktree = activeWorktreePath == null ||
        activeWorktreePath == mainWorktreePath ||
        (activeWorktree != null && activeWorktree.isMain);
    final worktreeBranch = activeWorktree?.branch;
    final effectiveBranch = isOnMainWorktree
        ? repo.branch
        : (worktreeBranch?.isNotEmpty == true
            ? worktreeBranch!
            : (activeWorktree?.head ?? repo.branch));

    final theme = Theme.of(context);
    final l = l10n(context);
    final sending = state.sending;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 420;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildBranchButton(
                      state: state,
                      projectId: projectId,
                      threadId: threadId,
                      repo: repo,
                      branches: branches,
                      effectiveBranch: effectiveBranch,
                      isOnMainWorktree: isOnMainWorktree,
                      sending: sending,
                      compact: compact,
                      theme: theme,
                      l: l,
                    ),
                    if (repo.behind > 0) ...[
                      const SizedBox(width: 2),
                      _HeaderAction(
                        label: '↓${repo.behind}',
                        tooltip: l.pull,
                        loading: _pulling,
                        onPressed: isOnMainWorktree && !sending
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
                        onPressed: isOnMainWorktree && !sending
                            ? () => _push(state, projectId)
                            : null,
                      ),
                    ],
                    const SizedBox(width: 8),
                    _buildWorktreeButton(
                      state: state,
                      projectId: projectId,
                      threadId: threadId,
                      repo: repo,
                      worktrees: worktrees,
                      mainWorktreePath: mainWorktreePath,
                      activeWorktree: activeWorktree,
                      activeWorktreePath: activeWorktreePath,
                      sending: sending,
                      compact: compact,
                      theme: theme,
                      l: l,
                    ),
                  ],
                );
              },
            ),
            if (_creatingBranch)
              _buildCreateBranchForm(state, projectId, branches, l, theme),
            if (_creatingWorktree)
              _buildCreateWorktreeForm(state, projectId, branches, repo, l, theme),
          ],
        ),
      ),
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
        onSelected: (value) => _onBranchMenuSelected(
          state,
          projectId,
          threadId,
          branches,
          value,
        ),
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
          child: _BranchItem(
            branch: b,
            isCurrent: isCurrent,
            theme: theme,
          ),
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
        value: '__create_branch__',
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
    if (value == '__create_branch__') {
      setState(() {
        _creatingBranch = !_creatingBranch;
        _creatingWorktree = false;
      });
      return;
    }
    final branch = _findBranch(branches, value);
    if (branch == null) return;
    final ok = await state.gitCheckout(projectId, branch.name, track: branch.isRemote);
    if (!ok) return;
    final repo = state.gitRepoInfo(projectId);
    final current = repo?.branch ?? branch.name;
    if (current.isNotEmpty) {
      await state.setThreadGit(threadId, branch: current);
    }
  }

  Widget _buildWorktreeButton({
    required AppState state,
    required int projectId,
    required String threadId,
    required GitRepoInfo repo,
    required List<GitWorktree> worktrees,
    required String mainWorktreePath,
    required GitWorktree? activeWorktree,
    required String? activeWorktreePath,
    required bool sending,
    required bool compact,
    required ThemeData theme,
    required AppLocalizations l,
  }) {
    final currentValue = activeWorktreePath ?? mainWorktreePath;
    final isOnMainWorktree = activeWorktreePath == null ||
        activeWorktreePath == mainWorktreePath ||
        (activeWorktree != null && activeWorktree.isMain);
    final label = isOnMainWorktree
        ? l.mainWorktree
        : (activeWorktree?.branch ??
            activeWorktree?.head ??
            activeWorktreePath.split('/').last);
    final icon = isOnMainWorktree ? Icons.folder : Icons.folder_copy;

    return PopupMenuButton<String?>(
      key: const Key('branch_toolbar_worktree'),
      enabled: !sending,
      tooltip: l.worktrees,
      offset: const Offset(0, -4),
      onSelected: (value) => _onWorktreeMenuSelected(
        state,
        projectId,
        threadId,
        worktrees,
        mainWorktreePath,
        value,
      ),
      itemBuilder: (context) => _buildWorktreeMenuItems(
        worktrees: worktrees,
        repo: repo,
        mainWorktreePath: mainWorktreePath,
        currentValue: currentValue,
        l: l,
        theme: theme,
      ),
      child: _ToolbarButton(
        icon: icon,
        label: label,
        compact: compact,
        foreground: theme.colorScheme.onSurfaceVariant,
        theme: theme,
      ),
    );
  }

  List<PopupMenuEntry<String?>> _buildWorktreeMenuItems({
    required List<GitWorktree> worktrees,
    required GitRepoInfo repo,
    required String mainWorktreePath,
    required String currentValue,
    required AppLocalizations l,
    required ThemeData theme,
  }) {
    final items = <PopupMenuEntry<String?>>[];
    items.add(
      PopupMenuItem<String?>(
        enabled: false,
        child: Text(
          l.worktrees,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
    items.add(const PopupMenuDivider(height: 8));

    final isCurrent = currentValue == mainWorktreePath;
    items.add(
      CheckedPopupMenuItem(
        value: mainWorktreePath,
        checked: isCurrent,
        child: _WorktreeItem(
          label: l.mainWorktree,
          sublabel: repo.branch,
          isMain: true,
          isCurrent: isCurrent,
          theme: theme,
        ),
      ),
    );

    for (final w in worktrees) {
      if (w.isMain && w.path == mainWorktreePath) continue;
      final isCurrent = w.path == currentValue;
      items.add(
        CheckedPopupMenuItem(
          value: w.path,
          checked: isCurrent,
          child: _WorktreeItem(
            label: w.branch ?? w.head,
            sublabel: w.path.split('/').last,
            isMain: w.isMain,
            isCurrent: isCurrent,
            theme: theme,
          ),
        ),
      );
    }

    if (!items
            .whereType<PopupMenuItem<String?>>()
            .any((i) => i.value == currentValue) &&
        currentValue != mainWorktreePath) {
      items.add(
        PopupMenuItem<String?>(
          value: currentValue,
          enabled: false,
          child: _WorktreeItem(
            label: currentValue.split('/').last,
            sublabel: currentValue,
            isMain: false,
            isCurrent: true,
            theme: theme,
          ),
        ),
      );
    }

    items.add(const PopupMenuDivider(height: 8));
    items.add(
      PopupMenuItem<String?>(
        value: '__create_worktree__',
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(l.createWorktree),
          ],
        ),
      ),
    );
    return items;
  }

  Future<void> _onWorktreeMenuSelected(
    AppState state,
    int projectId,
    String threadId,
    List<GitWorktree> worktrees,
    String mainWorktreePath,
    String? value,
  ) async {
    if (value == null) return;
    if (value == '__create_worktree__') {
      setState(() {
        _creatingWorktree = !_creatingWorktree;
        _creatingBranch = false;
      });
      return;
    }
    if (value == mainWorktreePath) {
      final repo = state.gitRepoInfo(projectId);
      await state.setThreadGit(
        threadId,
        branch: repo?.branch,
        worktreePath: null,
      );
      return;
    }
    final worktree = _findWorktree(worktrees, value);
    if (worktree == null) return;
    await state.setThreadGit(
      threadId,
      branch: worktree.branch,
      worktreePath: worktree.path,
    );
  }

  Widget _buildCreateBranchForm(
    AppState state,
    int projectId,
    List<GitBranch> branches,
    AppLocalizations l,
    ThemeData theme,
  ) {
    final branchNames = branches.map((b) => b.name).toList();
    final baseValue = _createBranchBase != null &&
            branchNames.contains(_createBranchBase)
        ? _createBranchBase
        : null;

    return _CompactForm(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _branchNameController,
            enabled: !_submitting,
            decoration: InputDecoration(
              labelText: l.branchName,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l.baseBranchOptional,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      isDense: true,
                      value: baseValue,
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
                      onChanged: _submitting
                          ? null
                          : (v) => setState(() => _createBranchBase = v),
                    ),
                  ),
                ),
              ),
              FilledButton(
                onPressed: _submitting
                    ? null
                    : () => _createBranch(state, projectId, switchBranch: false),
                child: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.createBranch),
              ),
              FilledButton(
                onPressed: _submitting
                    ? null
                    : () => _createBranch(state, projectId, switchBranch: true),
                child: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.createAndSwitchBranch),
              ),
              TextButton(
                onPressed: _submitting ? null : () => setState(() => _creatingBranch = false),
                child: Text(l.close),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createBranch(
    AppState state,
    int projectId, {
    required bool switchBranch,
  }) async {
    final name = _branchNameController.text.trim();
    if (name.isEmpty) return;
    final threadId = state.activeThreadId;
    setState(() => _submitting = true);
    try {
      final ok = await state.gitCreateBranch(
        projectId,
        name,
        base: _createBranchBase?.trim(),
        switchBranch: switchBranch,
      );
      if (!ok || !mounted) return;
      if (switchBranch && threadId != null) {
        final repo = state.gitRepoInfo(projectId);
        final current = repo?.branch ?? name;
        if (current.isNotEmpty) {
          await state.setThreadGit(threadId, branch: current);
        }
      }
    } finally {
      if (mounted && state.globalError.isEmpty) {
        setState(() {
          _submitting = false;
          _creatingBranch = false;
          _branchNameController.clear();
          _createBranchBase = null;
        });
      } else if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Widget _buildCreateWorktreeForm(
    AppState state,
    int projectId,
    List<GitBranch> branches,
    GitRepoInfo repo,
    AppLocalizations l,
    ThemeData theme,
  ) {
    final localBranches = branches.where((b) => !b.isRemote).toList();
    final branchNames = localBranches.map((b) => b.name).toList();
    final baseValue = _createWorktreeBase != null &&
            branchNames.contains(_createWorktreeBase)
        ? _createWorktreeBase
        : (branchNames.contains(repo.branch) && repo.branch.isNotEmpty
            ? repo.branch
            : (branchNames.isNotEmpty ? branchNames.first : null));

    return _CompactForm(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _worktreeNameController,
            enabled: !_submitting,
            decoration: InputDecoration(
              labelText: l.worktreeName,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l.baseBranch,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      isDense: true,
                      value: baseValue,
                      hint: Text(l.baseBranch),
                      items: branchNames
                          .map(
                            (name) => DropdownMenuItem<String?>(
                              value: name,
                              child: Text(name),
                            ),
                          )
                          .toList(),
                      onChanged: _submitting
                          ? null
                          : (v) => setState(() => _createWorktreeBase = v),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: _createWorktreeNewBranch,
                    onChanged: _submitting
                        ? null
                        : (v) => setState(() => _createWorktreeNewBranch = v),
                  ),
                  Text(l.newBranchInWorktree),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _submitting || baseValue == null
                    ? null
                    : () => _createWorktree(state, projectId, baseValue),
                child: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.createWorktree),
              ),
              TextButton(
                onPressed: _submitting ? null : () => setState(() => _creatingWorktree = false),
                child: Text(l.close),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createWorktree(
    AppState state,
    int projectId,
    String base,
  ) async {
    final name = _worktreeNameController.text.trim();
    if (name.isEmpty || base.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final threadId = state.activeThreadId;
      final worktree = await state.gitCreateWorktree(
        projectId,
        name,
        base,
        newBranch: _createWorktreeNewBranch,
      );
      if (worktree != null && threadId != null) {
        await state.setThreadGit(
          threadId,
          branch: worktree.branch,
          worktreePath: worktree.path,
        );
      }
    } finally {
      if (mounted && state.globalError.isEmpty) {
        setState(() {
          _submitting = false;
          _creatingWorktree = false;
          _worktreeNameController.clear();
          _createWorktreeBase = null;
          _createWorktreeNewBranch = false;
        });
      } else if (mounted) {
        setState(() => _submitting = false);
      }
    }
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
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
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

class _CompactForm extends StatelessWidget {
  final Widget child;
  const _CompactForm({required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: child,
      ),
    );
  }
}
