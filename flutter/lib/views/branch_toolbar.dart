import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

part 'branch_toolbar_items.dart';

/// Git branch and worktree controls that live beneath the chat composer,
/// similar to t3code. The branch display always tracks the repo's current
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
    final effectiveBranch = isOnMainWorktree
        ? repo.branch
        : (activeWorktree?.branch ?? repo.branch);

    final theme = Theme.of(context);
    final l = l10n(context);
    final sending = state.sending;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final branchControl = _buildBranchControl(
                  state: state,
                  projectId: projectId,
                  threadId: threadId,
                  repo: repo,
                  branches: branches,
                  effectiveBranch: effectiveBranch,
                  isOnMainWorktree: isOnMainWorktree,
                  sending: sending,
                  theme: theme,
                  l: l,
                );
                final worktreeControl = _buildWorktreeControl(
                  state: state,
                  projectId: projectId,
                  threadId: threadId,
                  repo: repo,
                  worktrees: worktrees,
                  mainWorktreePath: mainWorktreePath,
                  activeWorktree: activeWorktree,
                  activeWorktreePath: activeWorktreePath,
                  sending: sending,
                  l: l,
                  theme: theme,
                );
                if (constraints.maxWidth < 560) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      branchControl,
                      const SizedBox(height: 8),
                      worktreeControl,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: branchControl),
                    const SizedBox(width: 16),
                    Expanded(child: worktreeControl),
                  ],
                );
              },
            ),
            if (_creatingBranch) _buildCreateBranchForm(state, projectId, branches, l, theme),
            if (_creatingWorktree)
              _buildCreateWorktreeForm(state, projectId, branches, repo, l, theme),
          ],
        ),
      ),
    );
  }

  GitWorktree? _findWorktree(List<GitWorktree> worktrees, String path) {
    for (final w in worktrees) {
      if (w.path == path) return w;
    }
    return null;
  }

  Widget _buildBranchControl({
    required AppState state,
    required int projectId,
    required String threadId,
    required GitRepoInfo repo,
    required List<GitBranch> branches,
    required String effectiveBranch,
    required bool isOnMainWorktree,
    required bool sending,
    required ThemeData theme,
    required AppLocalizations l,
  }) {
    final branchItems = _buildBranchItems(
      branches: branches,
      currentBranch: effectiveBranch,
      isOnMainWorktree: isOnMainWorktree,
      theme: theme,
    );

    final value = _itemValueForBranch(effectiveBranch, branchItems);

    final actions = <Widget>[
      if (repo.behind > 0) ...[
        const SizedBox(width: 4),
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
        const SizedBox(width: 4),
        _HeaderAction(
          label: '↑${repo.ahead}',
          tooltip: l.push,
          loading: _pushing,
          onPressed: isOnMainWorktree && !sending
              ? () => _push(state, projectId)
              : null,
        ),
      ],
      if (isOnMainWorktree) ...[
        const SizedBox(width: 4),
        IconButton(
          iconSize: 18,
          icon: const Icon(Icons.add),
          tooltip: l.createBranch,
          onPressed: sending
              ? null
              : () => setState(() {
                _creatingBranch = !_creatingBranch;
                _creatingWorktree = false;
              }),
        ),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final dropdown = DropdownButton<String?>(
          isExpanded: true,
          isDense: true,
          underline: const SizedBox(),
          iconSize: 18,
          menuMaxHeight: 320,
          value: value,
          hint: Text(l.gitBranches),
          items: branchItems,
          onTap: () => unawaited(state.loadGitBranches(projectId)),
          onChanged: isOnMainWorktree && !sending
              ? (value) => _onBranchSelected(state, projectId, threadId, branches, value)
              : null,
        );
        if (constraints.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              dropdown,
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: actions,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [Expanded(child: dropdown), ...actions],
        );
      },
    );
  }

  Widget _buildWorktreeControl({
    required AppState state,
    required int projectId,
    required String threadId,
    required GitRepoInfo repo,
    required List<GitWorktree> worktrees,
    required String mainWorktreePath,
    required GitWorktree? activeWorktree,
    required String? activeWorktreePath,
    required bool sending,
    required AppLocalizations l,
    required ThemeData theme,
  }) {
    final items = _buildWorktreeItems(
      worktrees: worktrees,
      repo: repo,
      mainWorktreePath: mainWorktreePath,
      activeWorktree: activeWorktree,
      activeWorktreePath: activeWorktreePath,
      l: l,
      theme: theme,
    );
    final currentValue = activeWorktreePath ?? mainWorktreePath;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: DropdownButton<String?>(
            isExpanded: true,
            isDense: true,
            underline: const SizedBox(),
            iconSize: 18,
            menuMaxHeight: 320,
            value: currentValue,
            hint: Text(l.worktrees),
            items: items,
            onTap: () => unawaited(state.loadGitWorktrees(projectId)),
            onChanged: sending
                ? null
                : (value) => _onWorktreeSelected(
                    state,
                    projectId,
                    threadId,
                    worktrees,
                    mainWorktreePath,
                    value,
                  ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          iconSize: 18,
          icon: const Icon(Icons.add),
          tooltip: l.createWorktree,
          onPressed: sending
              ? null
              : () => setState(() {
                _creatingWorktree = !_creatingWorktree;
                _creatingBranch = false;
              }),
        ),
      ],
    );
  }

  List<DropdownMenuItem<String?>> _buildBranchItems({
    required List<GitBranch> branches,
    required String currentBranch,
    required bool isOnMainWorktree,
    required ThemeData theme,
  }) {
    final items = <DropdownMenuItem<String?>>[];
    final hasCurrent = branches.any((b) => b.name == currentBranch);
    if (!hasCurrent && currentBranch.isNotEmpty) {
      items.add(
        DropdownMenuItem(
          value: currentBranch,
          enabled: false,
          child: _BranchItem(name: currentBranch, isCurrent: true, theme: theme),
        ),
      );
    }

    final defaultIndex = branches.indexWhere((b) => b.isDefault);
    final defaultBranch = defaultIndex >= 0 ? branches[defaultIndex] : null;
    final others = branches.where((b) => !b.isDefault).toList();

    void addItem(GitBranch b) {
      final isCurrent = b.name == currentBranch;
      items.add(
        DropdownMenuItem(
          value: b.name,
          enabled: isOnMainWorktree && !isCurrent,
          child: _BranchItem(branch: b, isCurrent: isCurrent, theme: theme),
        ),
      );
    }

    if (defaultBranch != null) {
      addItem(defaultBranch);
    }
    for (final b in others) {
      addItem(b);
    }
    return items;
  }

  String? _itemValueForBranch(
    String currentBranch,
    List<DropdownMenuItem<String?>> items,
  ) {
    if (items.isEmpty) return null;
    for (final item in items) {
      if (item.value == currentBranch) return currentBranch;
    }
    return items.first.value;
  }

  List<DropdownMenuItem<String?>> _buildWorktreeItems({
    required List<GitWorktree> worktrees,
    required GitRepoInfo repo,
    required String mainWorktreePath,
    required GitWorktree? activeWorktree,
    required String? activeWorktreePath,
    required AppLocalizations l,
    required ThemeData theme,
  }) {
    final currentValue = activeWorktree?.path ?? activeWorktreePath ?? mainWorktreePath;
    final items = <DropdownMenuItem<String?>>[];

    items.add(
      DropdownMenuItem(
        value: mainWorktreePath,
        child: _WorktreeItem(
          label: l.mainWorktree,
          sublabel: repo.branch,
          isMain: true,
          isCurrent: currentValue == mainWorktreePath,
          theme: theme,
        ),
      ),
    );

    for (final w in worktrees) {
      if (w.isMain && w.path == mainWorktreePath) continue;
      final isCurrent = w.path == currentValue;
      items.add(
        DropdownMenuItem(
          value: w.path,
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

    final hasCurrent = items.any((i) => i.value == currentValue);
    if (!hasCurrent && currentValue != mainWorktreePath) {
      items.add(
        DropdownMenuItem(
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

    return items;
  }

  Future<void> _onBranchSelected(
    AppState state,
    int projectId,
    String threadId,
    List<GitBranch> branches,
    String? value,
  ) async {
    if (value == null || value.isEmpty) return;
    final branch = branches.firstWhere((b) => b.name == value);
    final ok = await state.gitCheckout(projectId, branch.name, track: branch.isRemote);
    if (!ok) return;
    final repo = state.gitRepoInfo(projectId);
    final current = repo?.branch ?? branch.name;
    if (current.isNotEmpty) {
      await state.setThreadGit(threadId, branch: current);
    }
  }

  Future<void> _onWorktreeSelected(
    AppState state,
    int projectId,
    String threadId,
    List<GitWorktree> worktrees,
    String mainWorktreePath,
    String? value,
  ) async {
    if (value == null) return;
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

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
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
    final branchNames = branches.map((b) => b.name).toList();
    final baseValue = _createWorktreeBase != null &&
            branchNames.contains(_createWorktreeBase)
        ? _createWorktreeBase
        : (branchNames.contains(repo.branch) && repo.branch.isNotEmpty
            ? repo.branch
            : (branchNames.isNotEmpty ? branchNames.first : null));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                      : () => _createWorktree(state, projectId),
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
      ),
    );
  }

  Future<void> _createWorktree(AppState state, int projectId) async {
    final name = _worktreeNameController.text.trim();
    final branches = state.gitBranches(projectId);
    final branchNames = branches.map((b) => b.name).toList();
    var base = _createWorktreeBase;
    if (base == null || !branchNames.contains(base)) {
      final repo = state.gitRepoInfo(projectId);
      base = branchNames.contains(repo?.branch) && repo?.branch.isNotEmpty == true
          ? repo!.branch
          : (branchNames.isNotEmpty ? branchNames.first : null);
    }
    if (name.isEmpty || base == null || base.isEmpty) return;
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
