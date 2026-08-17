import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

class GitBranchDialog extends StatefulWidget {
  const GitBranchDialog({super.key});

  @override
  State<GitBranchDialog> createState() => _GitBranchDialogState();
}

class _GitBranchDialogState extends State<GitBranchDialog> {
  final _branchController = TextEditingController();
  final _baseController = TextEditingController();
  final _worktreeController = TextEditingController();
  bool _creatingBranch = false;
  bool _creatingBranchSwitch = false;
  bool _creatingWorktree = false;
  bool _creatingWorktreeNewBranch = false;
  bool _pulling = false;
  bool _pushing = false;
  final _pullingBranches = <String>{};
  String _query = '';

  @override
  void dispose() {
    _branchController.dispose();
    _baseController.dispose();
    _worktreeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projectId = state.gitDialogProjectId;
    if (projectId == null) return const SizedBox.shrink();
    final repo = state.gitRepoInfo(projectId);
    final branches = state.gitBranches(projectId);
    final worktrees = state.gitWorktrees(projectId);
    final activeThread = state.activeThreadDetail?.thread;
    final currentBranch = (activeThread != null && activeThread.projectId == projectId)
        ? (activeThread.branch ?? repo?.branch ?? '')
        : (repo?.branch ?? '');

    return Stack(
      children: [
        ModalBarrier(
          color: Colors.black.withValues(alpha: 0.5),
          dismissible: false,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(context, repo, currentBranch),
                    const SizedBox(height: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (repo == null)
                              const SizedBox(
                                height: 200,
                                child: Center(child: CircularProgressIndicator()),
                              )
                            else if (!repo.isRepo)
                              _buildNotRepo(context)
                            else ...[
                              _buildSearchField(context),
                              const SizedBox(height: 12),
                              _BranchList(
                                branches: _filter(branches),
                                currentBranch: currentBranch,
                                onCheckout: (b) => _checkout(projectId, b),
                                onUseForThread: (b) => _useBranch(projectId, b),
                                onPull: (b) => _pullBranch(projectId, b),
                                pulling: _pullingBranches,
                              ),
                              const Divider(height: 32),
                              _buildCreateBranch(context, projectId, branches),
                              const SizedBox(height: 16),
                              _buildWorktreeSection(context, projectId, branches),
                              if (worktrees.isNotEmpty)
                                _buildWorktreeList(context, projectId, worktrees),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(l10n(context).close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, GitRepoInfo? repo, String currentBranch) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final projectId = state.gitDialogProjectId ?? 0;
    final title = repo != null && repo.isRepo ? repo.toplevel.split('/').last : l10n(context).gitBranches;
    final behind = repo?.behind ?? 0;
    final ahead = repo?.ahead ?? 0;
    return Row(
      children: [
        Expanded(
          child: Text(title, style: theme.textTheme.headlineSmall),
        ),
        if (repo != null && repo.isRepo) ...[
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              currentBranch,
              style: theme.textTheme.labelLarge,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (behind > 0 || ahead > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _TrackingCounts(ahead: ahead, behind: behind, style: theme.textTheme.labelLarge),
            ),
          const SizedBox(width: 8),
          if (behind > 0)
            Tooltip(
              message: l10n(context).pull,
              child: TextButton(
                key: const Key('gitBranchPullHeader'),
                onPressed: _pulling ? null : () => _pull(projectId),
                child: _pulling
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).pull),
              ),
            ),
          if (ahead > 0)
            Tooltip(
              message: l10n(context).push,
              child: TextButton(
                onPressed: _pushing ? null : () => _push(projectId),
                child: _pushing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).push),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildNotRepo(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(l10n(context).notAGitRepo),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        labelText: l10n(context).searchBranches,
        prefixIcon: const Icon(Icons.search),
        border: const OutlineInputBorder(),
      ),
      onChanged: (v) {
        setState(() => _query = v);
        final state = context.read<AppState>();
        final id = state.gitDialogProjectId;
        if (id != null) {
          state.loadGitBranches(id, query: v.isEmpty ? null : v);
        }
      },
    );
  }

  Widget _buildCreateBranch(BuildContext context, int projectId, List<GitBranch> branches) {
    final state = context.read<AppState>();
    final branchNames = branches.map((b) => b.name).toList();
    final baseValue = branchNames.contains(_baseController.text) ? _baseController.text : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n(context).createBranch, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _branchController,
          decoration: InputDecoration(
            labelText: l10n(context).branchName,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          // ignore: deprecated_member_use
          value: baseValue,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: l10n(context).baseBranchOptional,
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(l10n(context).none)),
            ...branches.map((b) => DropdownMenuItem(value: b.name, child: Text(b.name))),
          ],
          onChanged: _creatingBranch ? null : (v) => setState(() => _baseController.text = v ?? ''),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _creatingBranch
                    ? null
                    : () => _createBranch(state, projectId, switchBranch: false),
                child: _creatingBranch && !_creatingBranchSwitch
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).createBranch),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _creatingBranch
                    ? null
                    : () => _createBranch(state, projectId, switchBranch: true),
                child: _creatingBranch && _creatingBranchSwitch
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).createAndSwitchBranch),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWorktreeSection(BuildContext context, int projectId, List<GitBranch> branches) {
    final state = context.read<AppState>();
    final branchNames = branches.map((b) => b.name).toList();
    GitBranch? current;
    for (final b in branches) {
      if (b.isCurrent) {
        current = b;
        break;
      }
    }
    String? selectedBase;
    if (branchNames.contains(_baseController.text)) {
      selectedBase = _baseController.text;
    } else if (current != null) {
      selectedBase = current.name;
    } else if (branchNames.isNotEmpty) {
      selectedBase = branchNames.first;
    }
    final baseValue = selectedBase;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n(context).createWorktree, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _worktreeController,
          decoration: InputDecoration(
            labelText: l10n(context).worktreeName,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        if (branches.isNotEmpty)
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: baseValue,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n(context).baseBranch,
              border: const OutlineInputBorder(),
            ),
            items: branches.map((b) => DropdownMenuItem(value: b.name, child: Text(b.name))).toList(),
            onChanged: _creatingWorktree ? null : (v) => setState(() => _baseController.text = v ?? ''),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _creatingWorktree
                    ? null
                    : () => _createWorktree(state, projectId, newBranch: false),
                child: _creatingWorktree && !_creatingWorktreeNewBranch
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).createWorktree),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _creatingWorktree
                    ? null
                    : () => _createWorktree(state, projectId, newBranch: true),
                child: _creatingWorktree && _creatingWorktreeNewBranch
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n(context).createAndNewBranch),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWorktreeList(BuildContext context, int projectId, List<GitWorktree> worktrees) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(l10n(context).worktrees, style: theme.textTheme.titleSmall),
        ...worktrees.map((w) => ListTile(
              dense: true,
              title: Text(w.branch ?? w.head),
              subtitle: Text(w.path, style: theme.textTheme.bodySmall),
              trailing: w.isMain
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => state.gitDeleteWorktree(projectId, w.path),
                    ),
              onTap: () => _useWorktree(projectId, w),
            )),
      ],
    );
  }

  List<GitBranch> _filter(List<GitBranch> branches) {
    if (_query.isEmpty) return branches;
    final q = _query.toLowerCase();
    return branches.where((b) => b.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _createBranch(AppState state, int projectId, {required bool switchBranch}) async {
    final name = _branchController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _creatingBranch = true;
      _creatingBranchSwitch = switchBranch;
    });
    await state.gitCreateBranch(
      projectId,
      name,
      base: _baseController.text.trim().isEmpty ? null : _baseController.text.trim(),
      switchBranch: switchBranch,
    );
    if (mounted) {
      setState(() {
        _creatingBranch = false;
        _creatingBranchSwitch = false;
        _branchController.clear();
        _baseController.clear();
      });
    }
  }

  Future<void> _createWorktree(AppState state, int projectId, {required bool newBranch}) async {
    final name = _worktreeController.text.trim();
    final base = _baseController.text.trim();
    if (name.isEmpty || base.isEmpty) return;
    setState(() {
      _creatingWorktree = true;
      _creatingWorktreeNewBranch = newBranch;
    });
    await state.gitCreateWorktree(projectId, name, base, newBranch: newBranch);
    if (mounted) {
      setState(() {
        _creatingWorktree = false;
        _creatingWorktreeNewBranch = false;
        _worktreeController.clear();
      });
    }
  }

  Future<void> _checkout(int projectId, GitBranch branch) async {
    final state = context.read<AppState>();
    await state.gitCheckout(projectId, branch.name, track: branch.isRemote);
  }

  Future<void> _useBranch(int projectId, GitBranch branch) async {
    final state = context.read<AppState>();
    var threadId = state.activeThreadId;
    if (threadId == null) {
      await state.createNewThread(projectId: projectId);
      threadId = state.activeThreadId;
    }
    if (threadId != null) {
      await state.setThreadGit(threadId, branch: branch.name);
    }
  }

  Future<void> _useWorktree(int projectId, GitWorktree worktree) async {
    final state = context.read<AppState>();
    var threadId = state.activeThreadId;
    if (threadId == null) {
      await state.createNewThread(projectId: projectId);
      threadId = state.activeThreadId;
    }
    if (threadId != null) {
      await state.setThreadGit(
        threadId,
        branch: worktree.branch,
        worktreePath: worktree.path,
      );
    }
  }

  Future<void> _pull(int projectId) async {
    setState(() => _pulling = true);
    await context.read<AppState>().gitPull(projectId);
    if (mounted) {
      setState(() => _pulling = false);
    }
  }

  Future<void> _pullBranch(int projectId, GitBranch branch) async {
    if (_pullingBranches.contains(branch.name)) return;
    setState(() => _pullingBranches.add(branch.name));
    try {
      await context.read<AppState>().gitPullBranch(projectId, branch.name);
    } finally {
      if (mounted) {
        setState(() => _pullingBranches.remove(branch.name));
      }
    }
  }

  Future<void> _push(int projectId) async {
    setState(() => _pushing = true);
    await context.read<AppState>().gitPush(projectId);
    if (mounted) {
      setState(() => _pushing = false);
    }
  }
}

class _BranchList extends StatelessWidget {
  final List<GitBranch> branches;
  final String currentBranch;
  final ValueChanged<GitBranch> onCheckout;
  final ValueChanged<GitBranch> onUseForThread;
  final ValueChanged<GitBranch> onPull;
  final Set<String> pulling;

  const _BranchList({
    required this.branches,
    required this.currentBranch,
    required this.onCheckout,
    required this.onUseForThread,
    required this.onPull,
    required this.pulling,
  });

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) {
      return const Center(child: Text('No branches'));
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: branches.length,
      itemBuilder: (context, index) {
        final b = branches[index];
        final isCurrent = b.name == currentBranch;
        return ListTile(
          dense: true,
          leading: Icon(
            isCurrent
                ? Icons.check_circle
                : (b.isRemote ? Icons.cloud : Icons.call_split),
            color: isCurrent ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: b.isRemote
              ? const Text('remote')
              : (b.ahead > 0 || b.behind > 0)
                  ? _TrackingCounts(ahead: b.ahead, behind: b.behind, style: Theme.of(context).textTheme.bodySmall)
                  : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!b.isRemote && b.behind > 0) ...[
                TextButton(
                  onPressed: pulling.contains(b.name) ? null : () => onPull(b),
                  child: pulling.contains(b.name)
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n(context).pull),
                ),
                const SizedBox(width: 4),
              ],
              TextButton(
                onPressed: isCurrent ? null : () => onCheckout(b),
                child: const Text('Checkout'),
              ),
              TextButton(
                onPressed: isCurrent ? null : () => onUseForThread(b),
                child: const Text('Use'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TrackingCounts extends StatelessWidget {
  final int ahead;
  final int behind;
  final TextStyle? style;

  const _TrackingCounts({
    required this.ahead,
    required this.behind,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (behind > 0) parts.add('↓$behind');
    if (ahead > 0) parts.add('↑$ahead');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' '), style: style);
  }
}
